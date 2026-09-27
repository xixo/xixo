# frozen_string_literal: true

module Mutations
  class ConnectFeeds < BaseMutation
    argument :id, ID, required: true
    argument :other_id, ID, required: true
    argument :connected, Boolean, required: false,
             description: "False severs the edge instead of making it."

    field :feed, Types::FeedType, null: false

    def resolve(id:, other_id:, connected: true)
      feed = feed!(id)
      other = feed!(other_id)

      refused("a feed cannot connect to itself") if feed.id == other.id

      connected ? feed.connect!(other) : feed.disconnect!(other)
      [ feed, other ].each(&:reindex!)

      { feed: feed }
    end
  end
end
