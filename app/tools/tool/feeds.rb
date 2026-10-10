module Tool
  class Feeds < Base
    tool_name "feed"
    scope "xixo:catalog:read"

    EXCERPT = 6_000
    STEP_TEXT = 600
    PASSAGES = 8
    AROUND = 500
    FIND_WORDS = 8
    MEANT = 4
    WIDEST = AROUND * 3
    COMMON = %w[
      the and for are but not you your all any can had has have her his how its our out who why was were
      what when where which will with this that these those from into about there their them then than
      does did done been being also just only some such very would could should shall may might must
      much many need tell know want give show find get got say said like please thanks one ones put
    ].freeze

    description <<~TEXT
      One feed: a part of its text, or with find the passages that answer what was asked, then
      an outline of where each sheet or section starts, everything known about it, every place
      it lives, and what analysis drew out of each. Read a table or a section whole, from where
      the outline says it starts, before counting or adding anything up. With `do` it also acts:
      note it, rename it, analyze it again, set how long it lasts, or place a file that is staged
      and waiting for somewhere to live. A feed is a reference, not the bytes; the originals stay
      in the resources they came from.
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
        type: { type: "string", description: "For create: xixo:note, xixo:address or xixo:tag." },
        title: { type: "string" },
        note: { type: "string", description: "For note: what to write about it." },
        prompt: { type: "string", description: "For create of a xixo:address: what it should find." },
        resource: { type: "string", description: "For place: the key of the resource to store it in." },
        reason: { type: "string", description: "For place: why it belongs there, in one sentence." },
        from: {
          type: "integer",
          description: "For get: where in its text to start reading, as a character offset. Each get returns " \
                       "up to #{EXCERPT} characters and says where the next part starts."
        },
        find: {
          type: "string",
          description: "For get: what to look for in its text, in words or as a question. Instead of a part of " \
                       "the text, get returns the passages that mention those words or mean what was asked, each " \
                       "with where it starts, so a long document can be searched without reading all of it."
        },
        lasts: {
          type: "string",
          description: "For create and last: \"forever\", or how many days it lasts before it is forgotten. " \
                       "What is made while answering a question lasts 30 days unless this says otherwise."
        }
      }
    )

    def self.call(server_context:, id: nil, key: nil, title: nil, note: nil,
                  type: nil, prompt: nil, resource: nil, reason: nil, lasts: nil, from: nil, find: nil, **held)
      verb = (held[:do] || held["do"] || "get").to_s

      respond(server_context, { id: id, key: key, do: verb, type: type, title: title, resource: resource,
                                lasts: lasts, from: from, find: find }.compact) do
        raise ArgumentError, "no such action '#{verb}'" unless (READ + WRITE).include?(verb)

        Current.grant.permit!("xixo:catalog:write") if WRITE.include?(verb)

        act(verb, id: id, key: key, title: title, note: note, type: type, prompt: prompt,
                  resource: resource, reason: reason, lasts: lasts, from: from, find: find)
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
      return readable.find_by(id: arguments[:id]) if arguments[:id].present?

      key = arguments[:key].to_s
      key.present? ? readable.address(key) || readable.by_key(key).first : nil
    end

    def self.act(verb, id:, key:, title:, note:, type:, prompt:, resource: nil, reason: nil, lasts: nil, from: nil,
                 find: nil)
      return made(type: type, key: key, title: title, prompt: prompt, lasts: lasts) if verb == "create"

      feed = found(id, key)
      read!(feed)
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

      told(feed, from: from, find: find)
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

      readable.address(key) || readable.by_key(key.to_s).first ||
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

    SHOWN_ELSEWHERE = %w[text outline sheets tables].freeze

    def self.told(feed, from: nil, find: nil)
      steps = feed.analysis&.steps.to_h

      { id: feed.id.to_s, title: feed.title }
        .merge(find.present? ? found_in(feed, find) : part_of(feed, from))
        .merge({ outline: steps.dig("outline", "result") }.compact)
        .merge(summarize(feed))
        .merge(
          note: feed.note,
          summary: feed.summary,
          tags: feed.tags.map(&:key),
          mimes: feed.mimes.map(&:key),
          staged: staged(feed),
          connected: feed.connected.readable_by(Current.grant).limit(50).map { |held| { id: held.id.to_s, key: held.key } },
          steps: steps.except(*SHOWN_ELSEWHERE).transform_values { |step|
            step.key?("error") ? { "error" => step["error"]["message"] } : gist(step["result"])
          }
        )
    end

    def self.found_in(feed, find, budget: EXCERPT)
      body = feed.readable_text.to_s
      return { passages: [], text_part: { of: body.length } } if body.empty?

      ranked = (meant(feed, find) + worded(body, find)).each_with_object([]) do |(start, finish, by), held|
        joined = held.find { |one| start <= one[1] && finish >= one[0] }
        next held << [ start, finish, [ by ] ] if joined.nil?

        joined[0] = [ joined[0], start ].min
        joined[1] = [ joined[1], finish ].max
        joined[2] |= [ by ]
      end

      {
        found: ranked.size,
        text_part: { of: body.length },
        passages: fitted(ranked, budget).sort_by(&:first).map do |start, finish, by|
          { from: start, matched_by: by.join(" and "), text: body[start...finish] }
        end
      }
    end

    def self.fitted(ranked, budget)
      used = 0

      ranked.first(PASSAGES).take_while do |start, finish, _|
        used += finish - start
        used <= budget || used == finish - start
      end
    end

    def self.words(find)
      (find.to_s.downcase.scan(/[[:alnum:]]{3,}/).uniq - COMMON).first(FIND_WORDS)
    end

    def self.worded(body, find)
      words = words(find)
      return [] if words.empty?

      pattern = Regexp.new(words.map { |word| Regexp.escape(word) }.join("|"), Regexp::IGNORECASE)
      hits = body.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) }

      windows = hits.each_with_object([]) do |at, held|
        start = [ at - AROUND, 0 ].max
        finish = [ at + AROUND, body.length ].min
        next held.last[1] = finish if held.any? && start <= held.last[1] && finish - held.last[0] <= WIDEST

        held << [ start, finish ]
      end

      windows.map { |start, finish| [ start, finish, "words", body[start...finish].downcase.then { |text| words.count { |word| text.include?(word) } } ] }
             .sort_by { |start, _, _, matched| [ -matched, start ] }
             .map { |start, finish, by, _| [ start, finish, by ] }
    end

    def self.meant(feed, find)
      vector = Embedding.query(find)
      return [] if vector.nil?

      PassageIndex.nearest(vector, tenant: feed.tenant, limit: MEANT, feed_id: feed.id)
                  .map { |hit| [ hit.starts_at, hit.ends_at, "meaning" ] }
    end

    def self.part_of(feed, from)
      body = feed.readable_text.to_s
      return { text: nil } if body.empty?

      start = from.to_i.clamp(0, body.length)
      part = body[start, EXCERPT].to_s
      finish = start + part.length

      {
        text_part: { from: start, to: finish, of: body.length,
                     next: ({ id: feed.id.to_s, from: finish } if finish < body.length) }.compact,
        text: part
      }
    end

    def self.gist(value)
      return value unless value.is_a?(String) && value.length > STEP_TEXT

      "#{value.first(STEP_TEXT)}… (#{value.length} characters in all; read them as text)"
    end
  end
end
