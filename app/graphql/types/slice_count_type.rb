# frozen_string_literal: true

module Types
  class SliceCountType < Types::BaseObject
    field :key, String, null: false, hash_key: :key,
          description: "A resource id, an analysis state, a kind, or a span: day, week, month, or year."
    field :count, Integer, null: false, hash_key: :count
  end
end
