# frozen_string_literal: true

module Mutations
  class SetMachineHelpsOthers < BaseMutation
    description "Turns on or off whether a machine helps read files from elsewhere: uploads, mail attachments, cloud " \
                "files, web pages, and files other machines lend. xixo tells xixo link at once, and the machine's " \
                "own config can still keep it off."

    argument :id, ID, required: true
    argument :helps_others, Boolean, required: true,
             description: "Whether the machine helps read files from elsewhere."

    field :resource, Types::ResourceType, null: false

    def resolve(id:, helps_others:)
      context[:grant].administer!("turns on or off whether a machine helps read files from elsewhere")
      machine = Resource::Machine.visible_to(context[:grant]).find_by(id: id) || refused("no machine with id #{id}")

      machine.set_helps_others!(helps_others)
      AuditEvent.record(
        channel: "graphql", action: "set_machine_helps_others", status: "ok", grant: context[:grant],
        context: Current.audit,
        told: "turned #{helps_others ? 'on' : 'off'} helping read files from elsewhere on #{machine.key}",
        arguments: { "key" => machine.key, "helps_others" => helps_others }
      )

      { resource: machine }
    rescue Grant::Denied => e
      refused(e.message)
    end
  end
end
