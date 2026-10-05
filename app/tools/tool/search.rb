module Tool
  class Search < Base
    tool_name "search"
    scope "xixo:catalog:read"

    description <<~TEXT
      Search the whole catalog at once — every resource that has been synced, not one
      provider at a time. Matches titles, keys, paths, tags and text drawn out by analysis, and
      finds the passage inside a long document that means what was asked; a result found that
      way carries the passage and where it starts. Omit the query to list the most recent feeds,
      newest first. Every reply says how many matched in total.
    TEXT

    input_schema(
      properties: {
        query: { type: "string", description: "Words or a question. Matches the words, and what they mean." },
        type: {
          type: "string",
          description: "Leave it off to search everything. Restricts to one type: xixo:file, xixo:note, " \
                       "xixo:address, xixo:tag, xixo:mime."
        },
        limit: { type: "integer", minimum: 1, maximum: 200 }
      }
    )

    GIST = 300
    PASSAGE = 500

    def self.found(feed, passage = nil)
      told = summarize(feed).merge(gist: (feed.summary || feed.readable_text)&.squish&.truncate(GIST))
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
        wanted = limit.to_i.clamp(1, 200)
        page = searched(query, type, wanted)
        widened = page.nodes.empty? && type.present? && query.present?
        page = searched(query, nil, wanted) if widened
        widened &&= page.nodes.any?
        passages = type.present? && !widened ? {} : passages_for(query)

        {
          count: page.nodes.size,
          total: page.total,
          widened: (true if widened),
          note: noted(page, type, widened),
          feeds: page.nodes.map { |feed| found(feed, passages[feed.id]) }
        }.compact
      end
    end

    def self.noted(page, type, widened)
      told = []
      told << "Nothing of type #{type} matched, so these are every type that did. Leave type off to search everything." if widened
      told << "These are #{page.nodes.size} of #{page.total}. Raise limit, up to 200, or narrow the query or type for the rest." if page.has_more
      told.join(" ").presence
    end

    def self.searched(query, type, limit)
      found = Feed.found(query, type: type, limit: limit)
      kept = found.nodes.reject { |feed| feed.id == Current.acting_for }

      Page.new(kept, found.has_more, nil, found.total - (found.nodes.size - kept.size))
    end
  end
end
