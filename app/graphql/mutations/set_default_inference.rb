# frozen_string_literal: true

module Mutations
  class SetDefaultInference < BaseMutation
    argument :id, ID, required: true

    field :resource, Types::ResourceType, null: false

    def resolve(id:)
      resource = resource!(id)
      administers!
      refused("#{resource.key} is not inference") unless resource.inference?

      { resource: resource.make_default_inference! }
    end
  end
end
