# frozen_string_literal: true

module Mutations
  class RequestServerUpdate < BaseMutation
    description "Asks xixo-updater on this server to update now, pause, resume, roll back to the build before, or follow " \
                "another channel. The updater takes the request within a few seconds and records who asked."

    argument :action, String, required: true, description: "update_now, pause, resume, roll_back, or channel."
    argument :channel, String, required: false, description: "main or releases, with the channel action."

    field :server_updates, Types::ServerUpdatesType, null: false

    def resolve(action:, channel: nil)
      context[:grant].administer!("updates this server")
      refused("updates on this server are run by its operator") unless ServerUpdates.controlled_by?(context[:tenant])

      ServerUpdates.request!(action: action, channel: channel, by: context[:grant].subject)
      AuditEvent.record(
        channel: "graphql", action: "request_server_update", status: "ok", grant: context[:grant], context: Current.audit,
        told: action == "channel" ? "asked the updater to follow #{channel}" : "asked the updater to #{action.tr('_', ' ')}",
        arguments: { "action" => action, "channel" => channel }.compact
      )

      { server_updates: { status: ServerUpdates.status, events: ServerUpdates.events } }
    rescue Grant::Denied, ServerUpdates::Refused => e
      refused(e.message)
    end
  end
end
