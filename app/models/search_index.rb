module SearchIndex
  class Failed < StandardError; end

  VECTOR_DIMENSIONS = ENV.fetch("XIXO_EMBEDDING_DIMENSIONS", 768).to_i
  CANDIDATES = 200
  FUSION_RANK = 60
  LOOSE_MATCH = "60%".freeze
  LOOSE_AFTER_WORDS = 3
  SEMANTIC_MARGIN = 0.12
  SEMANTIC_FLOOR = ENV.fetch("XIXO_SEMANTIC_FLOOR", "0.55").to_f
  UNASKED = %w[
    a an and are as at be but by for if in into is it no not of on or such that the their then there
    these they this to was will with what when where which who whom whose why how do does did i me my
    mine we our us you your am have has had much many
  ].freeze

  SETTINGS = {
    index: { knn: true },
    analysis: {
      tokenizer: {
        path_parts: { type: "pattern", pattern: "[/\\\\\\-_.\\s]+" }
      },
      filter: {
        unasked: { type: "stop", stopwords: UNASKED }
      },
      analyzer: {
        path: { type: "custom", tokenizer: "path_parts", filter: [ "lowercase" ] },
        path_query: { type: "custom", tokenizer: "path_parts", filter: [ "lowercase", "unasked" ] },
        stemmed: { type: "custom", tokenizer: "standard", filter: [ "lowercase", "kstem" ] },
        stemmed_query: { type: "custom", tokenizer: "standard", filter: [ "lowercase", "unasked", "kstem" ] },
        plain_query: { type: "custom", tokenizer: "standard", filter: [ "lowercase", "unasked" ] }
      }
    }
  }.freeze

  STEMMED = { type: "text", analyzer: "stemmed", search_analyzer: "stemmed_query" }.freeze
  PATH = { type: "text", analyzer: "path", search_analyzer: "path_query" }.freeze
  PLAIN = { type: "text", analyzer: "standard", search_analyzer: "plain_query", fields: { stemmed: STEMMED } }.freeze

  MAPPING = {
    dynamic: false,
    properties: {
      tenant_id: { type: "long" },
      type: { type: "keyword" },
      mime: { type: "keyword" },
      tags: PATH.merge(fields: { raw: { type: "keyword" } }),
      key: PATH,
      title: PATH.merge(fields: { stemmed: STEMMED }),
      locator_key: PATH,
      note: PLAIN,
      summary: PLAIN,
      body: PLAIN,
      resource_ids: { type: "long" },
      created_at: { type: "date" },
      embedding: {
        type: "knn_vector",
        dimension: VECTOR_DIMENSIONS,
        method: { name: "hnsw", engine: "lucene", space_type: "cosinesimil" }
      }
    }
  }.freeze

  FIELDS = %w[title^3 title.stemmed^3 key^3 tags^3 note^2 note.stemmed^2 summary^2 summary.stemmed^2
              locator_key body body.stemmed].freeze

  STAMP = Digest::SHA256.hexdigest([ SETTINGS, MAPPING ].to_json).first(12).freeze

  class << self
    def client
      @client ||= OpenSearch::Client.new(url: ENV.fetch("OPENSEARCH_URL", "http://127.0.0.1:9201"))
    end

    def alias_name
      [ "xixo", Rails.env, ENV["TEST_ENV_NUMBER"].presence ].compact.join("_")
    end

    def alias_for(tenant)
      "#{alias_name}_t#{tenant.id}"
    end

    def versioned
      "#{alias_name}_v#{Time.current.utc.strftime('%Y%m%d%H%M%S%L')}"
    end

    def live_indices
      client.indices.get_alias(name: alias_name).keys
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      []
    end

    def live_index
      live_indices.first || (alias_name if legacy_index?)
    end

    def legacy_index?
      live_indices.empty? && client.indices.exists(index: alias_name)
    end

    def stamp_of(index)
      client.indices.get_mapping(index: index).dig(index, "mappings", "_meta", "stamp")
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      nil
    end

    def stale?
      live = live_index

      return Tenant.exists? if live.nil?

      stamp_of(live) != STAMP
    end

    def build!(name = versioned)
      client.indices.create(
        index: name,
        body: { settings: SETTINGS, mappings: MAPPING.merge(_meta: { stamp: STAMP }) }
      )
      name
    rescue OpenSearch::Transport::Transport::Errors::BadRequest => e
      raise unless e.message.include?("resource_already_exists_exception")

      name
    end

    def create!
      live_index || build!.tap do |name|
        client.indices.update_aliases(
          body: { actions: [ { add: { index: name, alias: alias_name } } ] }
        )
      end
    end

    def create_alias!(tenant, index: nil)
      client.indices.update_aliases(
        body: { actions: [ tenant_alias(tenant, index || create!) ] }
      )
    end

    def promote!(target, at_least:)
      refresh!(index: target)
      held = client.count(index: target)["count"]

      if held < at_least
        raise ArgumentError, "#{target} holds #{held} documents, fewer than the #{at_least} expected"
      end

      retired = live_indices - [ target ]
      client.indices.delete(index: alias_name, ignore: 404) if legacy_index?

      actions = [ { add: { index: target, alias: alias_name } } ]
      Tenant.find_each { |tenant| actions << tenant_alias(tenant, target) }
      retired.each { |name| actions << { remove: { index: name, alias: "#{alias_name}*" } } }

      client.indices.update_aliases(body: { actions: actions })
      retired.each { |name| client.indices.delete(index: name, ignore: 404) }

      target
    end

    def index(feed, into: alias_name)
      client.index(index: into, id: feed.id, body: document(feed))
    end

    def index_all(items, into: alias_name)
      items = items.to_a
      return 0 if items.empty?

      body = items.flat_map do |item|
        [ { index: { _index: into, _id: item.id } }, document(item) ]
      end

      response = client.bulk(body: body)
      refused = Array(response["items"]).filter_map { |item| item.dig("index", "error") }

      if refused.any?
        raise Failed, "#{refused.length} of #{items.length} documents were refused: " \
                      "#{refused.first['reason']}"
      end

      items.length
    end

    def delete(item, from: alias_name)
      client.delete(index: from, id: item.id)
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      nil
    end

    def document(feed)
      {
        tenant_id: feed.tenant_id,
        type: feed.type,
        mime: feed.mime,
        tags: feed.family_tags,
        key: feed.key,
        title: feed.title,
        note: feed.note,
        locator_key: originals(feed).map(&:locator_key).compact.join(" "),
        summary: [ *feed.summaries, feed.described_text ].compact_blank.join("\n"),
        body: feed.readable_text,
        resource_ids: originals(feed).map(&:resource_id),
        created_at: feed.created_at,
        embedding: feed.embedding.presence
      }.compact
    end

    def search(query, tenant: Current.tenant, type: nil, mime: nil, tag: nil, limit: 50, least: LOOSE_MATCH)
      page(query, tenant: tenant, type: type, mime: mime, tag: tag, limit: limit, least: least)[:ids]
    end

    def page(query, tenant: Current.tenant, type: nil, mime: nil, tag: nil, limit: 50, from: 0, least: LOOSE_MATCH)
      raise ArgumentError, "no tenant" if tenant.nil?

      facets = { type: type, mime: mime, tag: tag }
      vector = wanted_vector(query, limit: limit, from: from)

      if vector.nil?
        held = lexical(query, tenant: tenant, limit: limit, from: from, least: least, **facets)
        return held.merge(worded: held[:ids])
      end

      found = lexical(query, tenant: tenant, limit: CANDIDATES, from: 0, least: least, **facets)
      passages = facets.compact_blank.empty? ? PassageIndex.nearest(vector, tenant: tenant, limit: CANDIDATES) : []
      fused = fuse(found[:ids], nearest(vector, tenant: tenant, limit: CANDIDATES, **facets), passages.map(&:feed_id).uniq)

      { ids: fused.drop(from).first(limit), total: [ found[:total], fused.length ].max, worded: found[:ids] }
    end

    def lexical(query, tenant:, limit:, from:, type: nil, mime: nil, tag: nil, least: LOOSE_MATCH)
      facets = { type: type, mime: mime, tag: tag }
      wanted = from + limit
      strict = matched(query, tenant: tenant, size: wanted, **facets)

      if strict[:total] >= wanted || query.to_s.split.size < LOOSE_AFTER_WORDS
        return { ids: strict[:ids].drop(from).first(limit), total: strict[:total] }
      end

      loose = matched(query, tenant: tenant, size: wanted, least: least, **facets)

      { ids: (strict[:ids] + loose[:ids]).uniq.drop(from).first(limit),
        total: [ strict[:total], loose[:total] ].max }
    end

    def matched(query, tenant:, size:, least: nil, type: nil, mime: nil, tag: nil)
      must = if query.present?
        [ { multi_match: {
          query: query, fields: FIELDS,
          **(least ? { operator: "or", minimum_should_match: least } : { operator: "and", type: "bool_prefix" })
        } } ]
      else
        [ { match_all: {} } ]
      end

      must.concat(faceted(type: type, mime: mime, tag: tag))

      response = client.search(
        index: alias_for(tenant),
        body: {
          query: { bool: { must: must } },
          size: size, from: 0, track_total_hits: true, _source: false,
          **(query.present? ? {} : { sort: [ { created_at: "desc" } ] })
        }
      )

      {
        ids: response.dig("hits", "hits").map { |hit| hit["_id"].to_i },
        total: response.dig("hits", "total", "value").to_i
      }
    end

    def nearest(vector, tenant:, limit:, type: nil, mime: nil, tag: nil)
      must = [ { term: { tenant_id: tenant.id } } ]
      must.concat(faceted(type: type, mime: mime, tag: tag))

      response = client.search(
        index: alias_for(tenant),
        body: {
          query: { knn: { embedding: { vector: vector, k: limit, filter: { bool: { must: must } } } } },
          size: limit, _source: [ "embedding" ]
        }
      )

      close(vector, response.dig("hits", "hits"))
    rescue OpenSearch::Transport::Transport::Errors::BadRequest,
           OpenSearch::Transport::Transport::Errors::NotFound => e
      Rails.logger.warn("the search engine refused a vector query: #{e.message.truncate(200)}")
      []
    end

    def close(vector, hits)
      scored = hits.map { |hit| [ hit["_id"].to_i, cosine(vector, hit.dig("_source", "embedding")) ] }
                   .sort_by { |_id, score| -score }
      bar = [ SEMANTIC_FLOOR, scored.first&.last.to_f - SEMANTIC_MARGIN ].max

      scored.take_while { |_id, score| score >= bar }.map(&:first)
    end

    def cosine(one, other)
      return 0.0 if other.blank? || one.size != other.size

      dot = one.zip(other).sum { |a, b| a * b }
      norms = Math.sqrt(one.sum { |a| a * a }) * Math.sqrt(other.sum { |b| b * b })

      norms.zero? ? 0.0 : dot / norms
    end

    def faceted(type:, mime:, tag:)
      { type: type, mime: mime, "tags.raw": tag }.compact_blank
                                           .map { |field, value| { (value.is_a?(Array) ? :terms : :term) => { field => value } } }
    end

    def fuse(*lists)
      scored = Hash.new(0.0)

      lists.each do |ranked|
        ranked.each_with_index { |id, rank| scored[id] += 1.0 / (FUSION_RANK + rank + 1) }
      end

      scored.each_with_index
            .sort_by { |(_id, score), rank| [ -score, rank ] }
            .map { |(id, _score), _rank| id }
    end

    def refresh!(index: alias_name)
      client.indices.refresh(index: index)
    rescue OpenSearch::Transport::Transport::Errors::NotFound
      nil
    end

    def reset!
      indices = live_indices
      indices.each { |name| client.indices.delete(index: name, ignore: 404) }
      client.indices.delete(index: alias_name, ignore: 404) if indices.empty?

      create!
    end

    private

      def originals(feed)
        feed.references.select { |held| held.role == Reference::ORIGINAL }
      end

      def wanted_vector(query, limit:, from:)
        return nil if query.blank? || (from + limit) > CANDIDATES

        Embedding.query(query)
      end

      def tenant_alias(tenant, index)
        {
          add: {
            index: index,
            alias: alias_for(tenant),
            filter: { term: { tenant_id: tenant.id } }
          }
        }
      end
  end
end
