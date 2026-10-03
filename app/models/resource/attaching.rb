class Resource
  class Attaching
    class Refused < ArgumentError; end

    attr_reader :klass

    def initialize(type, grant:)
      @klass = Resource.attachable.find { |held| held.sti_name == type.to_s } ||
               raise(Refused, "#{type} is not a type that can be attached")
      @grant = grant
    end

    def attach!(key:, name: nil, settings: {}, via: nil, personal: false)
      named = key.to_s.strip
      resource = klass.new(key: named, name: name.presence&.strip || named,
                           owner_subject: personal ? @grant&.subject : nil)

      resource.details, resource.credentials = Settings.for(klass, settings || {})
      resource.via = transport!(via) if via.present?

      raise Refused, resource.errors.full_messages.to_sentence unless resource.save

      resource.check_on_arrival unless resource.delegated?
      resource
    rescue Settings::Missing => e
      raise Refused, e.message
    end

    def always_needed
      klass.attaching[:fields].select { |field| field[:required] && field[:shown_when].nil? }.map { |field| field[:name] }
    end

    def credentials
      klass.attaching[:fields].select { |field| field[:secret] || field[:held] == :credentials }.map { |field| field[:name] }
    end

    private

      def transport!(key)
        Resource.capable_of(:transport).reachable_by(@grant).find_by(key: key.to_s) ||
          raise(Refused, "#{key} is not a transport here")
      end
  end
end
