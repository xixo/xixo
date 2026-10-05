require "monitor"

class FakeSearchEngine
  Errors = OpenSearch::Transport::Transport::Errors

  class Indices
    def initialize(engine)
      @engine = engine
    end

    def create(index:, body: {}, **)
      @engine.create_index!(index, body)
    end

    def exists(index:, **)
      @engine.known?(index)
    end

    def delete(index:, ignore: nil, **)
      @engine.delete_index!(index, Array(ignore))
    end

    def get_alias(name:, **)
      @engine.carrying(name)
    end

    def update_aliases(body:, **)
      @engine.update_aliases!(body)
    end

    def refresh(index:, **)
      @engine.resolve!(index)
      { "_shards" => { "successful" => 1 } }
    end

    def get_mapping(index:, **)
      @engine.mapping_of(index)
    end

    def put_mapping(index:, body:, **)
      @engine.remap!(index, body)
    end
  end

  def initialize
    @indices = {}
    @documents = {}
    @mappings = {}
    @monitor = Monitor.new
  end

  def indices
    @wrapper ||= Indices.new(self)
  end

  def index(index:, id:, body:, **)
    @monitor.synchronize do
      name, = resolve!(index)
      @documents[name][id.to_s] = normalize(body)

      { "_index" => name, "_id" => id.to_s, "result" => "created" }
    end
  end

  def refusing_bulk(reason = "mapper_parsing_exception")
    @refusal = reason
    yield
  ensure
    @refusal = nil
  end

  def index_names
    @monitor.synchronize { @indices.keys }
  end

  def bulk(body:, **)
    @monitor.synchronize do
      if @refusal
        refused = body.each_slice(2).map { { "index" => { "error" => { "reason" => @refusal } } } }

        return { "errors" => true, "items" => refused }
      end

      items = body.each_slice(2).map do |action, document|
        written = normalize(action).fetch("index")
        name, = resolve!(written["_index"])
        id = written["_id"].to_s
        @documents[name][id] = normalize(document)

        { "index" => { "_index" => name, "_id" => id, "status" => 201 } }
      end

      { "errors" => false, "items" => items }
    end
  end

  def delete(index:, id:, **)
    @monitor.synchronize do
      name, = resolve!(index)
      raise Errors::NotFound, "no document #{id} in #{index}" unless @documents[name].delete(id.to_s)

      { "_index" => name, "_id" => id.to_s, "result" => "deleted" }
    end
  end

  def delete_by_query(index:, body:, **)
    @monitor.synchronize do
      name, filter = resolve!(index)
      found = matching(name, filter, normalize(body))
      found.each { |id, _| @documents[name].delete(id) }

      { "deleted" => found.length }
    end
  end

  def count(index:, **)
    @monitor.synchronize do
      name, filter = resolve!(index)

      { "count" => matching(name, filter, {}).length }
    end
  end

  def search(index:, body: {}, **)
    @monitor.synchronize do
      name, filter = resolve!(index)
      asked = normalize(body)
      found = nearest(name, filter, asked) || matching(name, filter, asked)
      window = found.drop(asked["from"].to_i).first(asked["size"] || 10)

      {
        "hits" => {
          "total" => { "value" => found.length },
          "hits" => window.map do |id, document|
            { "_index" => name, "_id" => id, "_score" => 1.0, "_source" => document }
          end
        }
      }
    end
  end

  def create_index!(name, body)
    @monitor.synchronize do
      if @indices.key?(name)
        raise Errors::BadRequest, "resource_already_exists_exception: #{name} exists already"
      end

      @indices[name] = {}
      @documents[name] = {}
      @mappings[name] = normalize(body)["mappings"] || {}

      { "acknowledged" => true, "index" => name }
    end
  end

  def mapping_of(name)
    @monitor.synchronize do
      held, = resolve!(name)

      { held => { "mappings" => @mappings.fetch(held, {}) } }
    end
  end

  def remap!(name, body)
    @monitor.synchronize do
      held, = resolve!(name)
      @mappings[held] = @mappings.fetch(held, {}).merge(normalize(body))

      { "acknowledged" => true }
    end
  end

  def delete_index!(name, ignore)
    @monitor.synchronize do
      unless @indices.key?(name)
        raise Errors::NotFound, "no such index #{name}" unless ignore.include?(404)

        return { "acknowledged" => true }
      end

      @indices.delete(name)
      @documents.delete(name)
      @mappings.delete(name)

      { "acknowledged" => true }
    end
  end

  def known?(name)
    @monitor.synchronize { @indices.key?(name) || @indices.any? { |_, held| held.key?(name) } }
  end

  def carrying(name)
    @monitor.synchronize do
      found = @indices.select { |_, held| held.key?(name) }
      raise Errors::NotFound, "no index carries #{name}" if found.empty?

      found.transform_values { |held| { "aliases" => held.transform_values { |filter| filter || {} } } }
    end
  end

  def update_aliases!(body)
    @monitor.synchronize do
      normalize(body).fetch("actions").each do |action|
        added = action["add"]
        removed = action["remove"]

        add_alias!(added) if added
        remove_alias!(removed) if removed
      end

      { "acknowledged" => true }
    end
  end

  def resolve!(name)
    name = name.to_s

    @monitor.synchronize do
      return [ name, nil ] if @indices.key?(name)

      carrier = @indices.find { |_, held| held.key?(name) }
      raise Errors::NotFound, "no such index or alias #{name}" if carrier.nil?

      [ carrier.first, carrier.last[name] ]
    end
  end

  private

    def add_alias!(action)
      name = action.fetch("index")
      raise Errors::NotFound, "no such index #{name}" unless @indices.key?(name)

      @indices[name][action.fetch("alias")] = action["filter"]
    end

    def remove_alias!(action)
      held = @indices[action.fetch("index")]
      return if held.nil?

      wanted = action.fetch("alias")

      if wanted.end_with?("*")
        held.delete_if { |name, _| name.start_with?(wanted.chomp("*")) }
      else
        held.delete(wanted)
      end
    end

    def nearest(name, filter, body)
      asked = body.dig("query", "knn", "embedding")
      return nil if asked.nil?

      wanted = Array(asked["vector"]).map(&:to_f)

      @documents.fetch(name, {})
        .select { |_, document| clause?(document, filter) && clause?(document, asked["filter"]) }
        .select { |_, document| Array(document["embedding"]).length == wanted.length }
        .sort_by { |id, document| [ -cosine(wanted, document["embedding"]), id.to_i ] }
        .first(asked["k"].to_i.positive? ? asked["k"].to_i : 10)
    end

    def cosine(one, two)
      held = Array(two).map(&:to_f)
      dot = one.each_with_index.sum { |value, index| value * held[index].to_f }
      size = Math.sqrt(one.sum { |value| value * value }) * Math.sqrt(held.sum { |value| value * value })

      size.zero? ? 0.0 : dot / size
    end

    def matching(name, filter, body)
      query = body.dig("query") || { "match_all" => {} }

      found = @documents.fetch(name, {})
        .select { |_, document| clause?(document, filter) && clause?(document, query) }
        .sort_by { |id, _| id.to_i }

      sorted(found, body["sort"])
    end

    def sorted(found, sort)
      return found if sort.blank?

      field, direction = Array(sort).first.first
      ordered = found.sort_by { |id, document| [ document[field].to_s, id.to_i ] }

      direction.to_s == "desc" ? ordered.reverse : ordered
    end

    def clause?(document, query)
      return true if query.nil? || query.empty?

      name, held = query.first

      case name
      when "match_all" then true
      when "bool" then Array(held["must"]).all? { |one| clause?(document, one) }
      when "term" then held.all? { |field, value| holds?(document[field.delete_suffix(".raw")], value) }
      when "multi_match" then multi_match?(document, held)
      else raise ArgumentError, "the fake engine does not understand #{name}"
      end
    end

    def holds?(held, value)
      return held.any? { |one| one.to_s == value.to_s } if held.is_a?(Array)

      held.to_s == value.to_s
    end

    def multi_match?(document, held)
      wanted = terms(held["query"])
      return true if wanted.empty?

      if held["operator"] == "or"
        needed = (wanted.size * held["minimum_should_match"].to_s.to_f / 100).floor.clamp(1, wanted.size)

        return held.fetch("fields").any? do |field|
          found = terms(document[field.split("^").first])
          wanted.count { |term| found.include?(term) } >= needed
        end
      end

      held.fetch("fields").any? do |field|
        found = terms(document[field.split("^").first])
        whole = held["type"] == "bool_prefix" ? wanted[0...-1] : wanted
        begun = held["type"] == "bool_prefix" ? wanted.last : nil

        whole.all? { |term| found.include?(term) } && (begun.nil? || found.any? { |term| term.start_with?(begun) })
      end
    end

    def terms(value)
      value.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
    end

    def normalize(value)
      value.deep_stringify_keys
    end
end
