# frozen_string_literal: true

module Mutations
  class ApproveLinkRequest < BaseMutation
    description "Approves a machine asking to link up, with the plan xixo made from its description. xixo hands " \
                "xixo link on it a single-use enrollment token for masks, and the machine shows up once it enrolls."

    argument :id, ID, required: true
    argument :off, [ String ], required: false,
             description: "The lines of the plan to leave off: catalog, extract, or models. The rest start on."

    field :request, Types::LinkRequestType, null: false

    def resolve(id:, off: [])
      held = LinkRequest.find_by(id: id) || refused("no machine is asking to link up with id #{id}")
      held.approve!(context[:grant], off: off)
      noted(held, "approve_link_request", "approved #{held.hostname} to link up#{" without #{off.to_sentence}" if off.any?}")

      { request: held }
    rescue Grant::Denied, LinkRequest::Refused, Resource::Failed => e
      refused(e.message)
    end

    private

      def noted(held, action, told)
        AuditEvent.record(
          channel: "graphql", action: action, status: "ok", grant: context[:grant], context: Current.audit,
          told: told, arguments: { "hostname" => held.hostname, "code" => held.user_code }
        )
      end
  end
end
