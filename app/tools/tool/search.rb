module Tool
  class Search < Base
    tool_name "search"
    scope "uris:catalog:read"

    description <<~TEXT
      Search the whole catalog at once — every resource that has been synced, not one
      provider at a time. Matches titles, keys, paths, tags and text drawn out by analysis, and
      finds the passage inside a long document that means what was asked; a result found that
      way carries the passage and where it starts. Omit the query to list the most recent feeds
      of a type.
    TEXT

    input_schema(
      properties: {
        query: { type: "string", description: "Words or a question. Matches the words, and what they mean." },
        type: {
          type: "string",
          description: "Restrict to one type: uris:file, uris:note, uris:feed, uris:tag, uris:mime."
        },
        limit: { type: "integer", minimum: 1, maximum: 200 }
      }
    )

    GIST = 300
    PASSAGE = 500

    def self.found(feed, passage = nil)
      told = summarize(feed).merge(gist: (feed.summary || feed.body_text)&.squish&.truncate(GIST))
      return told if passage.nil?

      told.merge(passage: { from: passage.starts_at, text: passage.text.squish.truncate(PASSAGE) })
    end

    def self.passages_for(query)
      vector = query.present? ? Embedding.query(query) : nil
      return {} if vector.nil?

      PassageIndex.nearest(vector, tenant: Current.tenant, limit: SearchIndex::CANDIDATES)
                  .group_by(&:feed_id).transform_values(&:first)
    end

    def self.saying(arguments)
      within = arguments[:type].present? ? " among #{arguments[:type]}" : ""

      arguments[:query].present? ? "searched for #{arguments[:query]}#{within}" : "listed the catalog#{within}"
    end

    def self.call(server_context:, query: nil, type: nil, limit: 50)
      respond(server_context, { query: query, type: type, limit: limit }) do
        feeds = Feed.search(query, type: type, limit: limit.to_i.clamp(1, 200))
                    .reject { |feed| feed.id == Current.acting_for }

        passages = type.present? ? {} : passages_for(query)

        { count: feeds.size, feeds: feeds.map { |feed| found(feed, passages[feed.id]) } }
      end
    end
  end
end
