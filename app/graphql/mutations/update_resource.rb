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
      changing = Resource::Changing.new(resource, grant: context[:grant])
      changing.change!(name: name, settings: settings, via: via)

      noted(resource, settings, changing.declared)

      { resource: resource, check_error: resource.check_error }
    rescue Resource::Changing::Refused => e
      refused(e.message)
    end

    private

      def noted(resource, settings, declared)
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
