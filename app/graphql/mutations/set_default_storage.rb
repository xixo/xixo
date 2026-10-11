# frozen_string_literal: true

module Mutations
  class SetDefaultStorage < BaseMutation
    argument :id, ID, required: true

    field :resource, Types::ResourceType, null: false

    def resolve(id:)
      resource = resource!(id)
      administers!
      refused("#{resource.key} is not storage") unless resource.storage?

      { resource: resource.make_default_storage! }
    end
  end
end
