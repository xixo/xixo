class Resource
  class Settings
    class Missing < ArgumentError; end
    class Unattachable < ArgumentError; end
    class Unoffered < Missing; end

    def self.for(klass, given, kept: {})
      new(klass, given, kept: kept).settle
    end

    def initialize(klass, given, kept: {})
      @klass = klass
      @given = given.to_h.stringify_keys
      @kept = kept.to_h.stringify_keys

      raise Unattachable, "#{klass.sti_name} is not a type that can be attached" if fields.nil?
    end

    def settle
      details = {}
      credentials = {}

      chosen = {}

      fields.each do |field|
        next unless shown?(field, chosen)

        raw = offered(field)

        if blank?(raw)
          raise Missing, "#{field[:label]} is needed" if field[:required]

          next
        end

        value = cast(raw, field[:kind])
        refuse_unoffered!(field, value)
        chosen[field[:name]] = value

        place(field[:held] == :credentials ? credentials : details, field[:name], value)
      end

      [ details, credentials ]
    end

    def named
      fields.map { |field| field[:name] }
    end

    private

      def fields
        return @fields if defined?(@fields)

        @fields = @klass.attaching&.fetch(:fields)
      end

      def shown?(field, chosen)
        condition = field[:shown_when]
        return true if condition.nil?

        condition.all? { |name, wanted| Array(wanted).map(&:to_s).include?(chosen[name.to_s].to_s) }
      end

      def refuse_unoffered!(field, value)
        return if field[:options].nil?
        return if field[:options].any? { |option| option[:value] == value }

        raise Unoffered, "#{field[:label]} is one of #{field[:options].map { |option| option[:value] }.join(', ')}"
      end

      def offered(field)
        held = @given[field[:name]]
        return held unless blank?(held)
        return @kept[field[:name]] if field[:held] == :credentials && !blank?(@kept[field[:name]])

        field[:value]
      end

      def blank?(value)
        return true if value.nil?
        return value.strip.empty? if value.respond_to?(:strip)

        value.respond_to?(:empty?) && value.empty?
      end

      def place(held, name, value)
        steps = name.split(".")
        leaf = steps.pop

        steps.reduce(held) { |nest, step| nest[step] ||= {} }[leaf] = value
      end

      def listed(raw)
        entries = raw.is_a?(Array) ? raw : raw.to_s.split(/\s+/)

        entries.map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
      end

      def cast(raw, kind)
        case kind
        when "integer" then raw.to_s.strip.to_i
        when "boolean" then ActiveModel::Type::Boolean.new.cast(raw)
        when "list" then listed(raw)
        else raw.to_s.strip
        end
      end
  end
end
