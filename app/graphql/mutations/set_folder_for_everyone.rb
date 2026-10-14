# frozen_string_literal: true

module Mutations
  class SetFolderForEveryone < BaseMutation
    description "Chooses who sees a folder that a machine shares, and what xixo cataloged from it: everyone " \
                "here, or only the people who operate the machine. A folder joins the catalog for its " \
                "machine's operators. Only an administrator who sees the folder changes this."

    argument :id, ID, required: true
    argument :everyone, Boolean, required: true,
             description: "Whether everyone here sees the folder. False keeps it for the machine's operators."

    field :resource, Types::ResourceType, null: false

    def resolve(id:, everyone:)
      folder = resource!(id)
      machine = folder.via
      refused("#{folder.key} is not a folder a machine shares") unless folder.is_a?(Resource::Filesystem) && machine.is_a?(Resource::Machine)

      machine.hold_for!(folder, everyone: everyone, grant: context[:grant])
      AuditEvent.record(
        channel: "graphql", action: "set_folder_for_everyone", status: "ok", grant: context[:grant],
        context: Current.audit,
        told: everyone ? "showed #{folder.key} to everyone" : "kept #{folder.key} for the operators of #{machine.key}",
        arguments: { "key" => folder.key, "everyone" => everyone }
      )

      { resource: folder }
    rescue Resource::Refused => e
      refused(e.message)
    end
  end
end
