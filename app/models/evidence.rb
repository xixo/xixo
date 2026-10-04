class Evidence
  Piece = Data.define(:feed, :section, :text)

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
  FOUND = 12
  ANY_WORD = "1".freeze
  ASKING = %w[much many need tell know want give show find get got say said like please thanks one ones put].freeze

  attr_reader :pieces, :tables

  def initialize(question, first: [], leaving_out: [])
    @question = question.to_s
    @first = first
    @leaving_out = leaving_out
    @pieces = []
    @tables = []
    gather
  end

  def feeds
    @pieces.map(&:feed).uniq
  end

  def empty? = @pieces.empty?

  def text
    @pieces.map(&:text).join("\n")
  end

  def told
    @pieces.map do |piece|
      named = [ "[feed #{piece.feed.id}] #{piece.feed.title.presence || piece.feed.key}", piece.section ].compact.join(" › ")
      "#{named}\n---\n#{piece.text.strip}\n---"
    end.join("\n\n")
  end

  private

    def gather
      left = BUDGET

      candidates.each do |feed|
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
                 .where.not(type: [ Feed::TAG, Feed::MIME ]).index_by(&:id)

      ids.filter_map { |id| held[id] }.first(FEEDS)
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
