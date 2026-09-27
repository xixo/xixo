# frozen_string_literal: true

module Mutations
  class TagFeeds < BaseMutation
    MOST = 200

    argument :ids, [ ID ], required: true
    argument :tag, String, required: true

    field :feeds, [ Types::FeedType ], null: false

    def resolve(ids:, tag:)
      key = tag.to_s.squish

      refused("a tag needs a name") if key.empty?
      refused("that tag is longer than #{Feed::MAX_KEY} characters") if key.length > Feed::MAX_KEY
      refused("no more than #{MOST} items can be tagged at once") if ids.size > MOST

      feeds = ids.uniq.map { |id| feed!(id) }
      refused("a tag, type or address cannot itself be tagged") if feeds.any?(&:singleton?)

      Feed.transaction { feeds.each { |feed| feed.file_under!(key) } }

      { feeds: feeds }
    end
  end
end
