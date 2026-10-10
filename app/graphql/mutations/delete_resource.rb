# frozen_string_literal: true

module Mutations
  class DeleteResource < BaseMutation
    argument :id, ID, required: true

    field :deleted, Boolean, null: false,
          description: "Whether the resource, which must be put away first, is gone and its key free to attach again."
    field :places, Integer, null: false,
          description: "How many places in it xixo stopped pointing at. A feed left with no place is forgotten " \
                       "unless it has a note, a lifetime, or an edge someone made."

    def resolve(id:)
      resource = Resource.attended.reachable_by(context[:grant]).find_by(id: id) || refused("no resource with id #{id}")
      key = resource.key
      type = resource.type

      places = resource.delete!

      noted(type, key, places)

      { deleted: true, places: places }
    rescue Resource::Refused => e
      refused(e.message)
    end

    private

      def noted(type, key, places)
        AuditEvent.record(
          channel: "graphql", action: "delete_resource", status: "ok",
          grant: context[:grant], context: Current.audit,
          told: "deleted #{key}, which held #{places} #{'place'.pluralize(places)}",
          arguments: { "type" => type, "key" => key, "places" => places }
        )
      end
  end
end
