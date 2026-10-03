class Resource
  class Changing
    class Refused < ArgumentError; end

    def initialize(resource, grant:)
      raise Refused, "#{resource.key} has nothing that can be changed here" if resource.class.attaching.nil?

      @resource = resource
      @grant = grant
    end

    def change!(name: nil, settings: nil, via: nil)
      @resource.name = name.strip if name.present?
      settle(settings) unless settings.nil?
      @resource.via = via.empty? ? nil : transport!(via) unless via.nil?

      raise Refused, @resource.errors.full_messages.to_sentence unless @resource.save

      @resource.check_on_arrival
      @resource
    end

    def declared
      @resource.class.attaching[:fields].map { |field| field[:name] }
    end

    def credentials
      @resource.class.attaching[:fields].select { |field| field[:secret] || field[:held] == :credentials }.map { |field| field[:name] }
    end

    private

      def settle(given)
        given = held.merge(given.to_h.stringify_keys)
        details, credentials = Settings.for(@resource.class, given, kept: @resource.credentials)

        @resource.details = unowned(@resource.details).merge(details)
        @resource.credentials = unowned(@resource.credentials).merge(credentials)
      rescue Settings::Missing => e
        raise Refused, e.message
      end

      def held
        (declared - credentials).index_with { |name| @resource.details.to_h.dig(*name.split(".")) }.compact
      end

      def unowned(kept)
        kept.to_h.reject { |name, _| declared.include?(name) || declared.any? { |field| field.start_with?("#{name}.") } }
      end

      def transport!(key)
        Resource.capable_of(:transport).reachable_by(@grant).find_by(key: key.to_s) ||
          raise(Refused, "#{key} is not a transport here")
      end
  end
end
