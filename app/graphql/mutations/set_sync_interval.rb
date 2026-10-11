# frozen_string_literal: true

module Mutations
  class SetSyncInterval < BaseMutation
    argument :id, ID, required: true
    argument :seconds, Integer, required: false,
             description: "How often to sync. Left off, the resource syncs only when asked."

    field :resource, Types::ResourceType, null: false

    def resolve(id:, seconds: nil)
      resource = resource!(id)
      managed!(resource)
      resource.sync_interval = seconds

      refused(resource.errors.full_messages.to_sentence) unless resource.save

      { resource: resource }
    end
  end
end
