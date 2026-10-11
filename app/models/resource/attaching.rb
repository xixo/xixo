class Resource
  class Attaching
    attr_reader :klass

    def initialize(type, grant:)
      @klass = Resource.attachable.find { |held| held.sti_name == type.to_s } ||
               raise(Refused, "#{type} is not a type that can be attached")
      @grant = grant
    end

    def attach!(key:, name: nil, settings: {}, via: nil, personal: false)
      unless personal || @grant&.administers?
        raise Refused, "only an administrator attaches a place everyone shares. Attach it as only yours, " \
                       "or #{Grant::ADMINISTERING.downcase_first}"
      end

      named = key.to_s.strip
      resource = klass.new(key: named, name: name.presence&.strip || named,
                           owner_subject: personal ? @grant&.speaks_for : nil)

      resource.details, resource.credentials = Settings.for(klass, settings || {})
      resource.via = Resource.transport!(via, @grant) if via.present?

      raise Refused, resource.errors.full_messages.to_sentence unless resource.save

      resource.check unless resource.delegated?
      resource
    rescue Settings::Missing => e
      raise Refused, e.message
    end

    def always_needed
      klass.attaching[:fields].select { |field| field[:required] && field[:shown_when].nil? }.map { |field| field[:name] }
    end

    def credentials = klass.credential_fields
  end
end
