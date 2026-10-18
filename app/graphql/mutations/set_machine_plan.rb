# frozen_string_literal: true

module Mutations
  class SetMachinePlan < BaseMutation
    description "Turns one line of a machine's plan on or off: catalog, extract, or models. A line that is not " \
                "possible stays off. The change takes effect at once, without touching the machine."

    argument :id, ID, required: true
    argument :key, String, required: true, description: "catalog, extract, or models."
    argument :on, Boolean, required: true

    field :resource, Types::ResourceType, null: false

    def resolve(id:, key:, on:)
      context[:grant].administer!("changes what a machine does")
      machine = Resource::Machine.visible_to(context[:grant]).find_by(id: id) || refused("no machine with id #{id}")

      machine.set_plan!(key, on)
      AuditEvent.record(
        channel: "graphql", action: "set_machine_plan", status: "ok", grant: context[:grant], context: Current.audit,
        told: "turned #{on ? 'on' : 'off'} #{key} on #{machine.key}",
        arguments: { "key" => machine.key, "line" => key, "on" => on }
      )

      { resource: machine }
    rescue Grant::Denied, Resource::Refused => e
      refused(e.message)
    end
  end
end
