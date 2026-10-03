# frozen_string_literal: true

module Mutations
  class AttachResource < BaseMutation
    argument :type, String, required: true
    argument :key, String, required: true
    argument :name, String, required: false
    argument :settings, GraphQL::Types::JSON, required: false,
             description: "One entry per field the type declares. Anything else is dropped."
    argument :personal, Boolean, required: false,
             description: "Only whoever attaches it can see and use it. Left off, everyone here can."
    argument :via, String, required: false,
             description: "The key of a transport to reach it through, such as a tailnet. Left off, it is reached directly."

    field :resource, Types::ResourceType, null: false
    field :check_error, String, description: "What the first check said, if it did not pass."
    field :connect_url, String,
          description: "Where to send the browser to connect it through masks, for a type that connects " \
                       "that way. Nothing is reachable until somebody does."

    def resolve(type:, key:, name: nil, settings: nil, personal: false, via: nil)
      klass = attachable!(type)

      named = key.to_s.strip
      resource = klass.new(key: named, name: name.presence&.strip || named,
                           owner_subject: personal ? context[:grant]&.subject : nil)

      settle(resource, klass, settings)
      resource.via = transport!(via) if via.present?

      refused(resource.errors.full_messages.to_sentence) unless resource.save

      noted(klass, resource, settings)

      return { resource: resource, connect_url: resource.connect_path } if resource.delegated?

      resource.check

      { resource: resource, check_error: resource.check_error }
    end

    private

      def attachable!(type)
        klass = Resource.attachable.find { |held| held.sti_name == type.to_s }

        klass || refused("#{type} is not a type that can be attached")
      end

      # Only what the type declares is read, so a caller cannot smuggle a key the
      # form never offered into details or credentials.
      def settle(resource, klass, given)
        resource.details, resource.credentials = Resource::Settings.for(klass, given || {})
      rescue Resource::Settings::Missing => e
        refused(e.message)
      end

      # The names of what was set, never the values — a credential does not belong
      # in the audit trail even redacted.
      def noted(klass, resource, settings)
        AuditEvent.record(
          channel: "graphql", action: "attach_resource", status: "ok",
          grant: context[:grant], context: { remote_ip: nil, request_id: nil },
          told: "attached #{resource.key}, a #{klass.sti_name} resource",
          arguments: {
            "type" => klass.sti_name, "key" => resource.key,
            "set" => ((settings || {}).keys & klass.attaching[:fields].map { |f| f[:name] }).join(", "),
            "via" => resource.via&.key
          }.compact
        )
      end
  end
end
