class Feed
  class Slice
    STATES = %w[analyzed waiting parked failed].freeze
    WITHIN = { "day" => 1.day, "week" => 1.week, "month" => 1.month, "year" => 1.year }.freeze
    PARTS = {
      where: %i[machine_id resource_id],
      analysis: %i[analysis],
      kind: %i[kind],
      when: %i[since before]
    }.freeze
    ANALYZED = "analyzed".freeze
    WAITING = "waiting".freeze
    PARKED = "parked".freeze
    FAILED = "failed".freeze

    attr_reader :machine_id, :resource_id, :analysis, :kind, :since, :before

    def self.from(given, grant: Current.grant)
      held = given.respond_to?(:to_h) ? given.to_h : {}

      new(**held.symbolize_keys.slice(*PARTS.values.flatten), grant: grant)
    end

    def initialize(machine_id: nil, resource_id: nil, analysis: nil, kind: nil, since: nil, before: nil, grant: Current.grant)
      @grant = grant
      @machine_id = machine_id.presence&.to_s
      @resource_id = resource_id.presence&.to_s
      @analysis = analysis.presence&.to_s
      @kind = kind.presence&.to_s
      @since = since.presence && Feed.moment(since)
      @before = before.presence && Feed.moment(before)

      if @analysis && !STATES.include?(@analysis)
        raise ArgumentError, "analysis is one of #{STATES.join(', ')}, not #{@analysis}"
      end
      return unless @kind && !MimeType.families.include?(@kind)

      raise ArgumentError, "kind is one of #{MimeType.families.join(', ')}, not #{@kind}"
    end

    def to_h
      { machine_id: machine_id, resource_id: resource_id, analysis: analysis, kind: kind, since: since, before: before }.compact
    end

    def empty?
      to_h.empty?
    end

    def apply(scope)
      scope = scope.where(id: Reference.where(resource_id: resource_ids).select(:feed_id)) unless resource_ids.nil?
      scope = scope.where(id: of_kind(kind).select(:id)) if kind
      scope = scope.where(id: in_state(analysis).select(:id)) if analysis
      scope = scope.where(created_at: since..) if since
      scope = scope.where(created_at: ...before) if before
      scope
    end

    def found(query, type: nil, mime: nil, tag: nil, limit: 50, from: 0)
      held = SearchIndex.page(query, type: type, mime: mime, tag: tag, limit: SearchIndex::CANDIDATES, from: 0, **indexed)
      kept = held[:ids].empty? ? [] : held[:ids] & apply(Feed.readable_by(@grant).where(id: held[:ids])).ids
      shown = kept.drop(from).first(limit)
      nodes = shown.empty? ? [] : Feed.readable_by(@grant).for_rows.where(id: shown).in_order_of(:id, shown).to_a

      Page.at(nodes, from: from, total: kept.size)
    end

    def indexed
      { resource_ids: resource_ids, since: since, before: before, kind: kind }.compact
    end

    def counts(base)
      {
        where: where_counts(without(:where).apply(base)),
        analysis: analysis_counts(without(:analysis).apply(base)),
        kind: kind_counts(without(:kind).apply(base)),
        when: when_counts(without(:when).apply(base))
      }
    end

    def without(part)
      Slice.new(**to_h.except(*PARTS.fetch(part)), grant: @grant)
    end

    def resource_ids
      return @resource_ids if defined?(@resource_ids)

      @resource_ids = if resource_id
        Resource.visible_to(@grant).where(id: resource_id).ids
      elsif machine_id
        on_machine
      end
    end

    private

      def on_machine
        resources = Resource.visible_to(@grant).to_a
        held = Resource::Machine.holding(resources)

        resources.select { |resource| held[resource.id]&.id&.to_s == machine_id }.map(&:id)
      end

      def latest
        Analysis.where.not(cause: "ask")
                .select("DISTINCT ON (analyses.feed_id) analyses.*")
                .reorder(:feed_id, id: :desc)
      end

      def ended(status, error: nil)
        held = Analysis.from(latest, :analyses).where(status: status)
        held = held.where(error: error) if error
        held.select(:feed_id)
      end

      def never
        Feed.files.where.not(id: Analysis.where.not(cause: "ask").select(:feed_id))
      end

      def in_state(state)
        case state
        when ANALYZED then Feed.where(id: ended("done"))
        when WAITING then Feed.where(id: ended(Analysis::OPEN)).or(never)
        when PARKED then Feed.where(id: ended(Analysis::PARKED))
        when FAILED then Feed.where(id: ended("failed")).or(Feed.where(id: ended("cancelled", error: Analysis::EXPIRED)))
        end
      end

      def state_of(status, error)
        case status
        when "done" then ANALYZED
        when *Analysis::OPEN then WAITING
        when Analysis::PARKED then PARKED
        when "failed" then FAILED
        when "cancelled" then FAILED if error == Analysis::EXPIRED
        end
      end

      def ids_of(scope)
        scope.except(:includes, :preload, :eager_load, :order).select(:id)
      end

      def where_counts(scope)
        Reference.originals.where(feed_id: ids_of(scope), resource_id: Resource.visible_to(@grant).select(:id))
                 .group(:resource_id).distinct.count(:feed_id)
                 .map { |id, count| { key: id.to_s, count: count } }
                 .sort_by { |held| -held[:count] }
      end

      def analysis_counts(scope)
        tallied = Hash.new(0)
        Analysis.from(latest.where(feed_id: ids_of(scope)), :analyses).group(:status, :error).count.each do |(status, error), count|
          state = state_of(status, error)
          tallied[state] += count if state
        end
        tallied[WAITING] += never.where(id: ids_of(scope)).count

        STATES.map { |state| { key: state, count: tallied[state] } }
      end

      def kind_counts(scope)
        tallied = Hash.new(0)
        Reference.originals.where(feed_id: ids_of(scope)).group(:mime).distinct.count(:feed_id).each do |mime, count|
          tallied[MimeType.family(mime)] += count
        end
        staged.where(record_id: ids_of(scope)).group("active_storage_blobs.content_type").distinct.count(:record_id).each do |mime, count|
          tallied[MimeType.family(mime)] += count
        end

        MimeType.families.map { |family| { key: family, count: tallied[family] } }
      end

      def staged
        ActiveStorage::Attachment.joins(:blob).where(record_type: Feed.name, name: "upload")
                                 .where.not(record_id: Reference.originals.select(:feed_id))
      end

      def of_kind(kind)
        blobs = MimeType.of_kind(ActiveStorage::Blob.all, "active_storage_blobs.content_type", kind)

        Feed.where(id: Reference.originals.of_kind(kind).select(:feed_id))
            .or(Feed.where(id: staged.where(blob_id: blobs.select(:id)).select(:record_id)))
      end

      def when_counts(scope)
        now = Time.current
        counted = WITHIN.map { |_name, span| "COUNT(*) FILTER (WHERE feeds.created_at >= '#{(now - span).utc.iso8601}')" }
        found = scope.except(:includes, :preload, :eager_load, :order).pick(Arel.sql(counted.join(", ")))

        WITHIN.keys.zip(Array(found)).map { |name, count| { key: name, count: count.to_i } }
      end
  end
end
