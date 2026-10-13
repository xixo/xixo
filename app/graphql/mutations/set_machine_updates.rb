# frozen_string_literal: true

module Mutations
  class SetMachineUpdates < BaseMutation
    description "Turns automatic updates of xixo link on a machine on or off. When on, xixo tells xixo link to update " \
                "to the build xixo ships each time it connects, and xixo link downloads it from xixo, checks it, and " \
                "restarts into it."

    argument :id, ID, required: true
    argument :automatic, Boolean, required: true, description: "Whether xixo updates xixo link on the machine."

    field :resource, Types::ResourceType, null: false

    def resolve(id:, automatic:)
      context[:grant].administer!("turns updates of xixo link on or off")
      machine = Resource::Machine.visible_to(context[:grant]).find_by(id: id) || refused("no machine with id #{id}")

      machine.set_updates!(automatic)
      AuditEvent.record(
        channel: "graphql", action: "set_machine_updates", status: "ok", grant: context[:grant], context: Current.audit,
        told: "turned #{automatic ? 'on' : 'off'} updates of xixo link on #{machine.key}",
        arguments: { "key" => machine.key, "automatic" => automatic }
      )

      { resource: machine }
    rescue Grant::Denied => e
      refused(e.message)
    end
  end
end
