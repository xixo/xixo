# frozen_string_literal: true

module Mutations
  class SetMachineAccess < BaseMutation
    description "Sets what xixo may do with a machine. search browses, searches, and reads the text xixo drew " \
                "out. files adds fetching whole files and running the machine's readers. writing adds writing " \
                "into the folders the machine marks writable. xixo tells xixo link at once, and the machine's own " \
                "config can only narrow it."

    argument :id, ID, required: true
    argument :access, String, required: false, description: "search, files, or writing."
    argument :helps_others, Boolean, required: false,
             description: "Whether the machine helps read files from elsewhere: uploads, mail attachments, cloud " \
                          "files, web pages, and files other machines lend."

    field :resource, Types::ResourceType, null: false

    def resolve(id:, access: nil, helps_others: nil)
      context[:grant].administer!("changes what xixo may do with a machine")
      machine = Resource::Machine.visible_to(context[:grant]).find_by(id: id) || refused("no machine with id #{id}")
      refused("#{access} is not search, files, or writing") unless access.nil? || Resource::Machine::ACCESS.include?(access)

      machine.set_access!(access: access, helps_others: helps_others)
      AuditEvent.record(
        channel: "graphql", action: "set_machine_access", status: "ok", grant: context[:grant], context: Current.audit,
        told: "set what xixo may do with #{machine.key}",
        arguments: { "key" => machine.key, "access" => machine.access, "helps_others" => machine.helps_others? }
      )

      { resource: machine }
    rescue Grant::Denied => e
      refused(e.message)
    end
  end
end
