# frozen_string_literal: true

module Mutations
  class UpdateResource < BaseMutation
    argument :id, ID, required: true
    argument :name, String, required: false
    argument :settings, GraphQL::Types::JSON, required: false,
             description: "One entry per field the type declares. A secret left empty keeps what it held."
    argument :via, String, required: false,
             description: "The key of a transport to reach it through. An empty string reaches it directly, " \
                          "and leaving it off keeps what it had."

    field :resource, Types::ResourceType, null: false
    field :check_error, String, description: "What the check after the change said, if it did not pass."

    def resolve(id:, name: nil, settings: nil, via: nil)
      resource = resource!(id)
      klass = resource.class

      refused("#{resource.key} has nothing that can be changed here") if klass.attaching.nil?

      resource.name = name.strip if name.present?
      settle(resource, klass, settings) unless settings.nil?
      resource.via = via.empty? ? nil : transport!(via) unless via.nil?

      refused(resource.errors.full_messages.to_sentence) unless resource.save

      noted(resource, settings)
      resource.check

      { resource: resource, check_error: resource.check_error }
    end

    private

      def settle(resource, klass, given)
        declared = klass.attaching[:fields].map { |field| field[:name] }
        details, credentials = Resource::Settings.for(klass, given, kept: resource.credentials)

        resource.details = unowned(resource.details, declared).merge(details)
        resource.credentials = unowned(resource.credentials, declared).merge(credentials)
      rescue Resource::Settings::Missing => e
        refused(e.message)
      end

      def unowned(held, declared)
        held.to_h.reject { |name, _| declared.include?(name) || declared.any? { |field| field.start_with?("#{name}.") } }
      end

      def noted(resource, settings)
        declared = resource.class.attaching[:fields].map { |field| field[:name] }

        AuditEvent.record(
          channel: "graphql", action: "update_resource", status: "ok",
          grant: context[:grant], context: { remote_ip: nil, request_id: nil },
          told: "changed the settings of #{resource.key}",
          arguments: {
            "type" => resource.class.sti_name, "key" => resource.key,
            "set" => (settings.to_h.reject { |_, value| value.to_s.strip.empty? }.keys & declared).join(", "),
            "via" => resource.via&.key
          }.compact
        )
      end
  end
end
