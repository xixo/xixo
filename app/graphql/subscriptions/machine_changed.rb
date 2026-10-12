# frozen_string_literal: true

module Subscriptions
  class MachineChanged < BaseSubscription
    argument :id, ID, required: false,
             description: "Watch one machine. Left off, every machine in the tenant."

    field :resource, Types::ResourceType, null: false

    def subscribe(id: nil)
      :no_response
    end

    def update(id: nil)
      return :no_update unless Resource.visible_to(context[:grant]).exists?(id: object.id)

      { resource: object }
    end
  end
end
