class Details
  Row = Data.define(:group, :step, :item, :label, :value)

  HIDDEN = (Analysis::BOOKKEEPING + %w[verified summary sections conversation deviation text ocr transcript tables]).freeze
  LAST = %w[metadata].freeze
  ITEMS = 20
  LIST = 24
  ROWS = 400
  VALUE = 400

  NAMES = {
    "metadata" => "Embedded in the file",
    "probe" => "Streams and tags",
    "info" => "Document",
    "signal" => "Sound",
    "location" => "Coordinates",
    "listing" => "Contents"
  }.freeze

  FIRST = %w[
    title name subject summary from to date organization description author creator artist
    make model lensid lensmodel lens datetimeoriginal createdate exposuretime fnumber iso
    focallength gpsposition imagesize width height megapixels duration pages pagecount
    album albumartist genre keywords
  ].freeze

  PAIRED = [ %w[label value], %w[name value], %w[key value] ].freeze

  def self.of(analysis)
    return [] if analysis.nil?

    new(analysis.steps).rows
  end

  def self.label(key)
    words = key.to_s
               .gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
               .gsub(/([a-z\d])([A-Z])/, '\1 \2')
               .gsub(/([a-z])(\d)/, '\1 \2')
               .tr("_-", "  ")
               .split

    words.each_with_index.map { |word, index|
      if word.match?(/\A[A-Z\d]{2,}\z/) then word
      elsif index.zero? then word[0].upcase + word[1..].downcase
      else word.downcase
      end
    }.join(" ")
  end

  def self.rank(key)
    plain = key.to_s.downcase.delete("^a-z0-9")
    [ FIRST.index(plain) || FIRST.size, plain ]
  end

  def initialize(steps)
    @steps = steps.to_h
  end

  def rows
    @rows = []

    shown.each do |name, held|
      @group = NAMES.fetch(name) { self.class.label(name) }
      @step = name
      top(held["result"])
    end

    @rows.first(ROWS)
  end

  private

    def shown
      @steps.select { |name, held| !HIDDEN.include?(name) && held.is_a?(Hash) && held["result"].present? }
            .sort_by { |name, held| [ LAST.include?(name) ? 1 : 0, held["started_at"].to_s ] }
    end

    def top(result)
      if records?(result)
        result.first(ITEMS).each_with_index { |record, index| walk(record, [], index + 1) }
      else
        walk(result, [], nil)
      end
    end

    def walk(value, path, item)
      case value
      when Hash
        return add(paired(value), item, said([], value["value"])) if paired(value)

        value.sort_by { |key, _| self.class.rank(key) }
             .each { |key, held| walk(held, path + [ self.class.label(key) ], item) }
      when Array
        if records?(value)
          value.first(ITEMS).each_with_index do |record, index|
            walk(record, path[..-2] + [ "#{path.last} #{index + 1}".strip ], item)
          end
        elsif value.none? { |held| held.is_a?(Array) || held.is_a?(Hash) }
          add(path.join(" · "), item, value.compact_blank.first(LIST).map { |held| said(path, held) }.join(", "))
        end
      else
        add(path.join(" · "), item, said(path, value))
      end
    end

    def paired(hash)
      pair = PAIRED.find { |keys| hash.keys.sort == keys.sort }
      pair && hash[pair.first].to_s.presence
    end

    def records?(value)
      value.is_a?(Array) && value.any? && value.all?(Hash)
    end

    def said(path, value)
      case value
      when true then "yes"
      when false then "no"
      when Float then value.round(4).to_s.delete_suffix(".0")
      when Integer
        path.last.to_s.match?(/\A(Bytes|Size)\z/) ? ActiveSupport::NumberHelper.number_to_human_size(value) : value.to_s
      else value.to_s.squish
      end
    end

    def add(label, item, text)
      return if text.blank? || @rows.size >= ROWS
      return unless (@said ||= Set.new).add?([ item, label.to_s.downcase, text.downcase ])

      @rows << Row.new(group: @group, step: @step, item: item, label: label.presence || @group, value: text.truncate(VALUE))
    end
end
