module Tool
  class Feeds < Base
    tool_name "feed"
    scope "uris:catalog:read"

    EXCERPT = 8_000
    STEP_TEXT = 600

    description <<~TEXT
      One feed: everything known about it, every place it lives, what analysis drew out of
      each, and an excerpt of its text. With `do` it also acts — note it, rename it, analyze
      it again, set how long it lasts, or place a file that is staged and waiting for somewhere
      to live. A feed is a reference, not the bytes; the originals stay in the resources they
      came from.
    TEXT

    READ = %w[get].freeze
    WRITE = %w[note rename analyze create place last].freeze

    input_schema(
      properties: {
        id: { type: "string", description: "The feed's id, as returned by search." },
        key: { type: "string", description: "An address, as /buy, instead of an id." },
        do: {
          type: "string",
          enum: READ + WRITE,
          description: "What to do. Defaults to get."
        },
        type: { type: "string", description: "For create: uris:note, uris:feed or uris:tag." },
        title: { type: "string" },
        note: { type: "string", description: "For note: what to write about it." },
        prompt: { type: "string", description: "For create of a uris:feed: what it should find." },
        resource: { type: "string", description: "For place: the key of the resource to store it in." },
        reason: { type: "string", description: "For place: why it belongs there, in one sentence." },
        from: {
          type: "integer",
          description: "For get: where in its text to start reading, as a character offset. Each get returns " \
                       "up to #{EXCERPT} characters and says where the next part starts."
        },
        lasts: {
          type: "string",
          description: "For create and last: \"forever\", or how many days it lasts before it is forgotten. " \
                       "What is made while answering a question lasts 30 days unless this says otherwise."
        }
      }
    )

    def self.call(server_context:, id: nil, key: nil, title: nil, note: nil,
                  type: nil, prompt: nil, resource: nil, reason: nil, lasts: nil, from: nil, **held)
      verb = (held[:do] || held["do"] || "get").to_s

      respond(server_context, { id: id, key: key, do: verb, type: type, title: title, resource: resource,
                                lasts: lasts, from: from }.compact) do
        raise ArgumentError, "no such action '#{verb}'" unless (READ + WRITE).include?(verb)

        Current.grant.permit!("uris:catalog:write") if WRITE.include?(verb)

        act(verb, id: id, key: key, title: title, note: note, type: type, prompt: prompt,
                  resource: resource, reason: reason, lasts: lasts, from: from)
      end
    end

    SAID = {
      "get" => "read", "note" => "wrote a note on", "rename" => "renamed", "analyze" => "analyzed again",
      "place" => "placed", "last" => "set how long it keeps"
    }.freeze

    def self.saying(arguments)
      verb = arguments[:do].to_s
      return "made a #{arguments[:type].presence || Feed::NOTE} called #{arguments[:title] || arguments[:key]}" if verb == "create"

      target = about(arguments)&.then { |feed| feed.title.presence || feed.key } ||
               arguments[:key].presence || arguments[:id].presence&.then { |id| "feed #{id}" } || "nothing"
      said = "#{SAID.fetch(verb, verb)} #{target}"

      case verb
      when "place" then "#{said} in #{arguments[:resource]}"
      when "rename" then "#{said} to #{arguments[:title]}"
      when "last" then "#{said}: #{arguments[:lasts]}"
      else said
      end
    end

    def self.about(arguments)
      return Feed.find_by(id: arguments[:id]) if arguments[:id].present?

      key = arguments[:key].to_s
      key.present? ? Feed.address(key) || Feed.by_key(key).first : nil
    end

    def self.act(verb, id:, key:, title:, note:, type:, prompt:, resource: nil, reason: nil, lasts: nil, from: nil)
      return made(type: type, key: key, title: title, prompt: prompt, lasts: lasts) if verb == "create"

      feed = found(id, key)
      confined!(feed) if WRITE.include?(verb)

      case verb
      when "note" then feed.update!(note: note.presence)
      when "rename" then feed.update!(title: title.to_s.strip.presence || feed.title)
      when "place" then placed(feed, resource, reason)
      when "last"
        raise ArgumentError, "last needs lasts: forever, or a number of days" if lasts.blank?

        feed.lasts!(lasts)
      when "analyze"
        within_budget!

        return summarize(feed).merge(analysis: feed.analyze!(cause: "manual").id.to_s)
      end

      told(feed, from: from)
    end

    def self.placed(feed, key, reason)
      raise ArgumentError, "place needs a reason" if reason.blank?

      destination = ::Resource.visible_to(Current.grant).find_by(key: key.to_s.strip.delete_prefix("`").delete_suffix("`"))
      return Placement.new(feed).place!(destination, reason: reason) if destination

      accepting = Placement.candidates(feed).pluck(:key)
      raise ArgumentError, "no resource called #{key}" if accepting.empty?

      raise ArgumentError, "no resource called #{key}; the ones that accept this feed are #{accepting.to_sentence}"
    end

    def self.found(id, key)
      return feed!(id) if id.present?
      raise ArgumentError, "feed needs an id or a key" if key.blank?

      Feed.address(key) || Feed.by_key(key.to_s).first ||
        raise(ArgumentError, "no feed at #{key}")
    end

    def self.made(type:, key:, title:, prompt:, lasts: nil)
      wanted = type.presence || Feed::NOTE
      raise ArgumentError, "this run can only make notes" if Current.confined_to && wanted != Feed::NOTE

      feed = Feed.create!(type: wanted, key: key.presence || title.to_s, title: title)

      feed.create_schedule!(prompt: prompt) if wanted == Feed::ADDRESS && prompt.present?
      lasting(feed, lasts)

      told(made!(feed))
    end

    def self.staged(feed)
      held = feed.staged
      return nil if held.nil?

      { path: held.path, mime: held.mime, size: held.size,
        accepted_by: Placement.candidates(feed).pluck(:key) }
    end

    def self.told(feed, from: nil)
      summarize(feed).merge(
        note: feed.note,
        summary: feed.summary,
        keywords: feed.keywords,
        tags: feed.tags.map(&:key),
        mimes: feed.mimes.map(&:key),
        staged: staged(feed),
        connected: feed.connected.limit(50).map { |held| { id: held.id.to_s, key: held.key } },
        steps: feed.analysis&.steps.to_h.transform_values { |step|
          step.key?("error") ? { "error" => step["error"]["message"] } : gist(step["result"])
        }
      ).merge(part_of(feed, from))
    end

    def self.part_of(feed, from)
      body = feed.body_text.to_s
      return { text: nil } if body.empty?

      start = from.to_i.clamp(0, body.length)
      part = body[start, EXCERPT].to_s
      finish = start + part.length

      {
        text: part,
        text_part: { from: start, to: finish, of: body.length,
                     next: ({ id: feed.id.to_s, from: finish } if finish < body.length) }.compact
      }
    end

    def self.gist(value)
      return value unless value.is_a?(String) && value.length > STEP_TEXT

      "#{value.first(STEP_TEXT)}… (#{value.length} characters in all; read them as text)"
    end
  end
end
