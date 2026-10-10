# frozen_string_literal: true

module Mutations
  class SplitReference < BaseMutation
    argument :id, ID, required: true,
             description: "The reference to move to a feed of its own. The new feed carries the old one's connections " \
                          "and note, and stays apart from references with the same bytes until its own bytes change."

    field :feed, Types::FeedType, null: false

    def resolve(id:)
      reference = Reference.reachable_by(context[:grant]).find_by(id: id) ||
                  refused("no reference with id #{id}")

      refused("a feed with one reference is already split") if
        reference.feed.references.originals.size == 1

      reference.split!.update!(kept_apart: true)

      { feed: reference.feed }
    end
  end
end
