# frozen_string_literal: true

module Mutations
  class DenyLinkRequest < BaseMutation
    description "Denies a machine asking to link up. xixo link on it stops waiting and says so."

    argument :id, ID, required: true

    field :request, Types::LinkRequestType, null: false

    def resolve(id:)
      held = LinkRequest.find_by(id: id) || refused("no machine is asking to link up with id #{id}")
      held.deny!(context[:grant])
      AuditEvent.record(
        channel: "graphql", action: "deny_link_request", status: "ok", grant: context[:grant], context: Current.audit,
        told: "denied #{held.hostname}", arguments: { "hostname" => held.hostname, "code" => held.user_code }
      )

      { request: held }
    rescue Grant::Denied, LinkRequest::Refused => e
      refused(e.message)
    end
  end
end
