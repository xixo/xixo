# frozen_string_literal: true

module Mutations
  class ApproveLinkRequest < BaseMutation
    description "Approves a machine asking to link up. xixo hands xixo link on it a single-use enrollment token " \
                "for masks, and the machine shows up once it enrolls. It starts with Search access and helps read " \
                "other machines' files."

    argument :id, ID, required: true

    field :request, Types::LinkRequestType, null: false

    def resolve(id:)
      held = LinkRequest.find_by(id: id) || refused("no machine is asking to link up with id #{id}")
      held.approve!(context[:grant])
      noted(held, "approve_link_request", "approved #{held.hostname} to link up")

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
