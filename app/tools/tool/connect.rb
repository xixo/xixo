module Tool
  class Connect < Base
    tool_name "connect"
    scope "xixo:catalog:write"

    description <<~TEXT
      Connect two feeds, or sever the connection. A connection is symmetric and carries no
      direction — what it means is read from the two things joined. Connecting a document to
      a tag is how it is filed; connecting it to another document is how they are related.
    TEXT

    input_schema(
      properties: {
        a: { type: "string", description: "One feed's id." },
        b: { type: "string", description: "The other feed's id. Leave it off to name a tag instead." },
        tag: {
          type: "string",
          description: "The name of the tag to file a under. It is made if it does not exist yet."
        },
        connected: {
          type: "boolean",
          description: "False severs the connection instead of making it. Defaults to true."
        }
      },
      required: [ "a" ]
    )

    def self.call(a:, server_context:, b: nil, tag: nil, connected: true)
      respond(server_context, { a: a, b: b, tag: tag, connected: connected }) do
        one = feed!(a)
        unfit!(one, tag) if b.blank? && connected != false
        other = other_end(b, tag, connected)

        raise ArgumentError, "a feed cannot connect to itself" if one.id == other.id

        confined!(one, other, also: Current.acting_for)
        touched!(one)
        touched!(other)

        connected ? one.connect!(other) : one.disconnect!(other)

        { connected: connected, a: summarize(one), b: summarize(other) }
      end
    end

    def self.saying(arguments)
      one = named(arguments[:a])
      other = arguments[:b].present? ? named(arguments[:b]) : arguments[:tag].to_s.strip.delete_prefix("tag:").strip
      filing = arguments[:b].blank?

      if arguments[:connected] == false
        filing ? "took #{one} out of #{other}" : "disconnected #{one} from #{other}"
      else
        filing ? "filed #{one} under #{other}" : "connected #{one} to #{other}"
      end
    end

    def self.about(arguments)
      readable.find_by(id: arguments[:a])
    end

    def self.unfit!(one, tag)
      named = tag.to_s.strip.delete_prefix("tag:").strip
      return if named.empty? || Feed.fit_tag?(named, one)

      raise ArgumentError, "#{named} is not a tag. A tag names a topic, the kind of thing it is, or a person, " \
                           "company, product or place, never the file's own name, a date, or a number"
    end

    def self.other_end(b, tag, connected)
      named = tag.to_s.strip.delete_prefix("tag:").strip

      raise ArgumentError, "connect needs b, a feed id, or tag, a tag's name" if b.blank? && named.empty?
      return feed!(b) if b.present?

      found = Feed.tag_named(named)
      return found if found
      raise ArgumentError, "there is no tag called #{named}" unless connected

      Feed.tag!(named)
    end
  end
end
