class Evidence
  Piece = Data.define(:feed, :section, :text)
  Glimpse = Data.define(:feed, :gist)

  BUDGET = 24_000
  WHOLE = 10_000
  SECTION = 7_000
  SECTIONS = 3
  FEEDS = 5
  WORDED = 2
  LONG = 30
  HEAD = 4
  MATCHING = 15
  FOUND = 40
  GLANCED = 20
  GIST = 240
  ANY_WORD = "1".freeze
  DESCRIBED = "As a model described what it shows".freeze

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
    @text ||= (@pieces.map(&:text) + @glimpses.map(&:gist)).join("\n")
  end

  def told
    @told ||= [ read_told, glimpses_told ].compact_blank.join("\n\n")
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
      Current.grant&.read_privately!(ranked.first(FEEDS + GLANCED))

      @glimpses = wide.lazy.filter_map do |feed|
        gist = feed.summary.presence || feed.described_text
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
      found = SearchIndex.page(keywords, limit: FOUND, least: ANY_WORD)
      ids = (@first.map(&:id) + found[:worded].first(WORDED) + found[:ids]).uniq
      asked = Analysis.where(cause: "ask").select(:feed_id)

      Feed.readable_by(Current.grant).where(id: ids).in_order_of(:id, ids).where.not(id: @leaving_out.map(&:id)).where.not(id: asked)
          .where.not(type: [ Feed::TAG, Feed::MIME ]).includes(:analyses, children: :analyses).to_a
    end

    def keywords
      @keywords ||= Tool::Feeds.words(@question).join(" ").presence || @question
    end

    def read(feed, tables)
      described = feed.described_text

      [ ([ "Note", feed.note ] if feed.note.present?),
        ([ DESCRIBED, described.truncate(SECTION) ] if described.present?),
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
      (Tool::Feeds.meant(feed, @question) + Tool::Feeds.worded(body, keywords)).map(&:first).uniq
    end

    def sections(body, outline, starts)
      starts.filter_map { |from| Outline.at(outline, from) }.uniq.first(SECTIONS).map do |name|
        from = outline.find { |held| held["name"] == name }["from"].to_i
        to = Outline.span(outline, from, body.length).last

        [ name, body[from...to].truncate(SECTION) ]
      end.presence || windows(body, starts)
    end

    def every_section(body, outline)
      first = Outline.starts(outline).first.to_i
      lead = first.positive? ? [ [ nil, body[0...first] ] ] : []

      lead + outline.map do |part|
        from, to = Outline.span(outline, part["from"].to_i, body.length)
        [ part["name"], body[from...to] ]
      end
    end

    def windows(body, starts)
      starts.first(SECTIONS).map { |from| [ nil, body[from, SECTION / SECTIONS] ] }
    end
end
