# frozen_string_literal: true

module Subscriptions
  class LinkRequestChanged < BaseSubscription
    description "Fires when a machine asks to link up, and when its request is approved, denied, or linked. " \
                "Only an administrator hears it."

    field :request, Types::LinkRequestType, null: false

    def subscribe
      :no_response
    end

    def update
      return :no_update unless context[:grant]&.administers?

      { request: object }
    end
  end
end
