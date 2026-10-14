# frozen_string_literal: true

module Types
  class FeedPageType < Types::BaseObject
    field :nodes, [ Types::FeedType ], null: false
    field :next_cursor, ID
    field :has_more, Boolean, null: false
    field :total, Integer,
          description: "How many match altogether, counted only when asked for."
  end
end
