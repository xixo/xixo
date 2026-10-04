class Evidence
  Piece = Data.define(:feed, :section, :text)
  Glimpse = Data.define(:feed, :gist)

  BUDGET = 24_000
  WHOLE = 10_000
  SECTION = 7_000
  SECTIONS = 3
  MEANT = 6
  FEEDS = 5
  WORDED = 2
  LONG = 30
  HEAD = 4
  MATCHING = 15
  FOUND = 40
  GLANCED = 20
  GIST = 240
  ANY_WORD = "1".freeze
  ASKING = %w[much many need tell know want give show find get got say said like please thanks one ones put].freeze

  attr_reader :pieces, :tables, :glimpses

  def initialize(question, first: [], leaving_out: [])
    @question = question.to_s
    @first = first
    @leaving_out = leaving_out
    @pieces = []
    @tables = []
    @glimpses = []
    gather
  end

  def feeds
    (@pieces.map(&:feed) + @glimpses.map(&:feed)).uniq
  end

  def empty? = @pieces.empty? && @glimpses.empty?

  def text
    (@pieces.map(&:text) + @glimpses.map(&:gist)).join("\n")
  end

  def told
    [ read_told, glimpses_told ].compact_blank.join("\n\n")
  end

  private

    def named(feed)
      "[feed #{feed.id}] #{feed.title.presence || feed.key}"
    end

    def read_told
      @pieces.chunk_while { |one, other| one.feed == other.feed }.map do |held|
        parts = held.map { |piece| [ ("--- #{piece.section} ---" if piece.section), piece.text.strip ].compact.join("\n") }
        "#{named(held.first.feed)}, read in full#{', by its sections' if held.many?}:\n#{parts.join("\n")}\n--- end of feed #{held.first.feed.id} ---"
      end.join("\n\n")
    end

    def glimpses_told
      return nil if @glimpses.empty?

      listed = @glimpses.map { |held| "- #{named(held.feed)}: #{held.gist}" }
      "Other items the search found, known only by a model's summary of each:\n#{listed.join("\n")}"
    end

    def gather
      left = BUDGET
      ranked = candidates
      deep, wide = ranked.first(FEEDS), ranked.drop(FEEDS)

      @glimpses = wide.filter_map do |feed|
        gist = [ feed.summary, feed.described_text ].compact_blank.first
        Glimpse.new(feed: feed, gist: gist.squish.truncate(GIST)) if gist
      end.first(GLANCED)

      deep.each do |feed|
        break if left <= 0

        tables = Tables.of(feed)

        read(feed, tables).each do |section, text|
          held = text.to_s.strip.truncate(left)
          next if held.blank?

          @pieces << Piece.new(feed: feed, section: section, text: held)
          left -= held.length
        end

        @tables.concat(tables.map { |table| table.merge("feed" => feed.id) })
      end
    end

    def candidates
      found = SearchIndex.search(keywords, limit: FOUND, least: ANY_WORD)
      worded = SearchIndex.lexical(keywords, tenant: Current.tenant, limit: WORDED, from: 0, least: ANY_WORD)[:ids]
      ids = (@first.map(&:id) + worded + found).uniq
      asked = Analysis.where(cause: "ask").select(:feed_id)
      held = Feed.where(id: ids).where.not(id: @leaving_out.map(&:id)).where.not(id: asked)
                 .where.not(type: [ Feed::TAG, Feed::MIME ]).includes(:analyses, children: :analyses).index_by(&:id)

      ids.filter_map { |id| held[id] }
    end

    def keywords
      words = @question.downcase.scan(/[[:alnum:]][[:alnum:]'.-]*[[:alnum:]]/).reject { |word| word.length < 3 }
      (words - Tool::Feeds::COMMON - ASKING).uniq.join(" ").presence || @question
    end

    DESCRIBED = "As a model described what it shows".freeze

    def read(feed, tables)
      [ ([ "Note", feed.note ] if feed.note.present?),
        ([ DESCRIBED, feed.described_text.truncate(SECTION) ] if feed.described_text.present?),
        *parts(feed).map { |section, text| [ section, shortened(text, tabled(tables, section)) ] } ].compact
    end

    def tabled(tables, section)
      tables.find { |table| table["name"] == section } || (tables.first if tables.one? && section.nil?)
    end

    def shortened(text, table)
      return text if table.nil? || table["rows"].size <= LONG

      lines = text.lines
      words = keywords.split
      matching = lines.drop(HEAD).select { |line| words.any? { |word| line.downcase.include?(word) } }.first(MATCHING)

      [ *lines.first(HEAD), *matching,
        "(#{table['rows'].size} rows in all, #{matching.size} of them shown for mentioning #{words.to_sentence}. " \
        "A total or a count over them is worked out with compute.)" ].join.strip
    end

    def parts(feed)
      body = feed.readable_text.to_s
      return [] if body.blank?

      outline = feed.outline
      return [ [ nil, body ] ] if body.length <= WHOLE && outline.empty?
      return every_section(body, outline) if body.length <= WHOLE

      starts = ranked(feed, body).presence || [ 0 ]
      return windows(body, starts) if outline.empty?

      sections(body, outline, starts)
    end

    def ranked(feed, body)
      vector = Embedding.query(@question)
      meant = vector ? PassageIndex.nearest(vector, tenant: feed.tenant, limit: MEANT, feed_id: feed.id).map(&:starts_at) : []

      (meant + Tool::Feeds.worded(body, keywords).map(&:first)).uniq
    end

    def sections(body, outline, starts)
      bounds = Outline.starts(outline) + [ body.length ]

      starts.filter_map { |from| Outline.at(outline, from) }.uniq.first(SECTIONS).map do |name|
        part = outline.find { |held| held["name"] == name }
        from = part["from"].to_i
        to = bounds.find { |at| at > from } || body.length

        [ name, body[from...to].truncate(SECTION) ]
      end.presence || windows(body, starts)
    end

    def every_section(body, outline)
      bounds = Outline.starts(outline) + [ body.length ]
      lead = bounds.first.to_i.positive? ? [ [ nil, body[0...bounds.first] ] ] : []

      lead + outline.map do |part|
        from = part["from"].to_i
        [ part["name"], body[from...(bounds.find { |at| at > from } || body.length)] ]
      end
    end

    def windows(body, starts)
      starts.uniq.first(3).map do |from|
        [ nil, body[[ from - 500, 0 ].max, SECTION / 3] ]
      end
    end
end
