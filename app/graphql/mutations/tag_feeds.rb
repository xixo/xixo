# frozen_string_literal: true

module Mutations
  class TagFeeds < BaseMutation
    MOST = 200

    argument :ids, [ ID ], required: true, description: "The items to change, up to 200."
    argument :tag, String, required: true,
             description: "The name of the tag. Underscores read as spaces, runs of whitespace collapse to one, case is ignored, and a tag that does not exist yet is created."
    argument :tagged, Boolean, required: false,
             description: "Set to false to remove the tag from the items. It defaults to true."

    field :feeds, [ Types::FeedType ], null: false, description: "The items after the change."

    def resolve(ids:, tag:, tagged: true)
      key = Feed.tag_name(tag)

      refused("a tag needs a name") if key.empty?
      refused("that tag is longer than #{Feed::MAX_KEY} characters") if key.length > Feed::MAX_KEY
      refused("no more than #{MOST} items can be tagged at once") if ids.size > MOST

      wanted = ids.uniq
      held = Feed.where(id: wanted).index_by { |feed| feed.id.to_s }
      missing = wanted.find { |id| !held.key?(id.to_s) }

      refused("no feed with id #{missing}") if missing

      feeds = wanted.map { |id| held.fetch(id.to_s) }
      refused("a tag, type or address cannot itself be tagged") if feeds.any?(&:singleton?)

      apply(feeds, key, tagged)

      Feed.reindex!(feeds)

      { feeds: feeds }
    end

    private

      def apply(feeds, key, tagged)
        if tagged
          tag = Feed.tag!(key)
          Feed.transaction { feeds.each { |feed| feed.connect!(tag) } }
        elsif (tag = Feed.tag_named(key))
          Feed.transaction { feeds.each { |feed| feed.disconnect!(tag) } }
        end
      end
  end
end
