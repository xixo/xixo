# frozen_string_literal: true

module Mutations
  class ArchiveResource < BaseMutation
    argument :id, ID, required: true
    argument :archived, Boolean, required: true,
             description: "Put it away, or bring it back."

    field :resource, Types::ResourceType, null: false

    def resolve(id:, archived:)
      resource = Resource.attended.reachable_by(context[:grant]).find_by(id: id) || refused("no resource with id #{id}")
      managed!(resource)

      resource.archived_at = archived ? Time.current : nil

      refused(resource.errors.full_messages.to_sentence) unless resource.save

      noted(resource, archived)

      { resource: resource }
    end

    private

      def noted(resource, archived)
        AuditEvent.record(
          channel: "graphql", action: archived ? "archive_resource" : "restore_resource",
          status: "ok", grant: context[:grant], context: Current.audit,
          told: "#{archived ? 'archived' : 'restored'} #{resource.key}",
          arguments: { "type" => resource.type, "key" => resource.key }
        )
      end
  end
end
