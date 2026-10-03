class Resource
  class Changing
    attr_reader :declared

    def initialize(resource, grant:)
      raise Refused, "#{resource.key} has nothing that can be changed here" if resource.class.attaching.nil?

      @resource = resource
      @grant = grant
      @declared = resource.class.attaching[:fields].map { |field| field[:name] }
    end

    def change!(name: nil, settings: nil, via: nil)
      @resource.name = name.strip if name.present?
      settle(settings) unless settings.nil?
      @resource.via = via.empty? ? nil : Resource.transport!(via, @grant) unless via.nil?

      raise Refused, @resource.errors.full_messages.to_sentence unless @resource.save

      @resource.check
      @resource
    end

    def credentials = @resource.class.credential_fields

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
  end
end
