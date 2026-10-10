# frozen_string_literal: true

module Subscriptions
  class FeedAnalyzed < BaseSubscription
    argument :id, ID, required: false,
             description: "Watch one feed. Left off, every feed in the tenant."

    field :feed, Types::FeedType, null: false

    def subscribe(id: nil)
      :no_response
    end

    def update(id: nil)
      return :no_update unless object.readable_by?(context[:grant])

      { feed: object }
    end
  end
end
