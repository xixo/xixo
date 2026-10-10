class Analysis < ApplicationRecord
  CAUSES = %w[upload sync keep schedule manual ask].freeze
  STATUSES = %w[queued running done failed cancelled gated].freeze
  OPEN = %w[queued running].freeze
  SETTLED = %w[done failed].freeze
  BOOKKEEPING = %w[placement derived answer drew_on].freeze
  SOURCE = %w[text ocr transcript conversation place].freeze
  DESCRIBED = %w[caption scenes].freeze
  BULK = %w[sync].freeze
  ASKED_PRIORITY = 0

  LOG_LIMIT = 256_000
  LINE_LIMIT = 2_000
  MAX_REQUEST = 40_000
  MAX_RESPONSE = 4_000

  include TenantScoped

  belongs_to :feed
  belongs_to :reference, optional: true
  belongs_to :about, class_name: "Feed", optional: true

  validates :cause, inclusion: { in: CAUSES }
  validates :status, inclusion: { in: STATUSES }

  before_create :remember_who_asked

  scope :open, -> { where(status: OPEN) }
  scope :readable_by, ->(grant) { where(feed_id: Feed.readable_by(grant).select(:id)) }
  scope :settled, -> { where(status: SETTLED) }
  scope :newest_first, -> { reorder(id: :desc) }
  scope :past_deadline, -> { open.where(deadline: ...Time.current) }

  def self.open!(feed:, cause:, reference: nil, deadline: nil)
    create!(feed: feed, cause: cause, reference: reference,
            deadline: deadline || default_deadline,
            steps: feed.analysis&.steps || {})
  end

  def self.default_deadline
    budget = Rails.configuration.xixo.run_deadline

    budget.to_i.zero? ? nil : budget.from_now
  end

  def open? = OPEN.include?(status)

  def grant(scopes: Feed::AGENT_SCOPES)
    feed.grant(scopes: scopes, speaking_for: requested_by)
  end

  def settled? = SETTLED.include?(status)
  def bulk? = BULK.include?(cause)

  def running!
    started = started_at || Time.current
    due = started + allowed
    moved = Analysis.where(id: id, status: OPEN).update_all(status: "running", started_at: started, deadline: due)
    return moved if moved.zero?

    self.status = "running"
    self.started_at = started
    self.deadline = due
    clear_attribute_changes(%i[status started_at deadline])
    moved
  end

  def allowed
    return feed.time_allowed if cause != "ask" || feed.timeout.present?

    Resource.for_role(Resource::OpenaiCompatible::AGENT_ROLE)&.time_allowed || Feed::ASK_TIMEOUT
  end

  def more_time!(wanted)
    ceiling = (started_at || created_at) + Feed::MAX_TIMEOUT

    Analysis.where(id: id).update_all([
      "deadline = LEAST(GREATEST(COALESCE(deadline, now()), now()) + make_interval(secs => ?), ?)",
      wanted.to_i, ceiling
    ])
    held_deadline
  end

  def time_left
    due = held_deadline
    return nil if due.nil?

    [ due - Time.current, 0 ].max
  end

  def finished!(error: nil)
    return if %w[cancelled gated].include?(current_status)

    update_columns(
      status: error ? "failed" : "done",
      error: Redaction.scrub(error)&.truncate(500),
      finished_at: Time.current
    )

    refiled!(tagged: error.nil?)
  end

  def refiled!(tagged: true)
    feed.tag_with!(tags) if tagged
    Feed.where(id: feed_id).where.not(embedded_at: nil).update_all(embedded_at: nil)
    SearchIndex.index(feed.reload)
    publish!
  end

  def handed_off!
    moved = Analysis.where(id: id, status: OPEN)
                    .update_all(status: "queued", started_at: nil, deadline: self.class.default_deadline)
    return false if moved.zero?

    reload
    publish!
    true
  end

  def gated!
    return false unless open?

    update_columns(status: "gated", finished_at: Time.current)
    publish!
    true
  end

  def cancel!
    moved = Analysis.where(id: id, status: OPEN).update_all(status: "cancelled", finished_at: Time.current)
    reload
    return false if moved.zero?

    publish!
    true
  end

  def halted?
    fresh = current_status
    return true if fresh.nil?

    self.status = fresh
    return true if fresh == "cancelled"

    expired?
  end

  def expired?
    ended = { status: "cancelled", error: "deadline passed", finished_at: Time.current }
    return false if Analysis.past_deadline.where(id: id).update_all(ended).zero?

    assign_attributes(ended)
    clear_attribute_changes(ended.keys)
    true
  end

  def duration_ms
    return nil if started_at.nil? || finished_at.nil?

    ((finished_at - started_at) * 1000).round
  end

  def step(name)
    steps[name.to_s] || {}
  end

  def step_result(name)
    step(name)["result"]
  end

  def write_step!(name, entry)
    held = self.class.storable(entry)

    merge_column!(:steps, { name.to_s => held })
    steps[name.to_s] = held
    clear_attribute_changes([ :steps ])
    held
  end

  def extracted
    steps.slice(*SOURCE).values.filter_map { |held| held["result"] }
  end

  def own_text
    extracted.find { |held| held.is_a?(String) }
  end

  def described
    steps.slice(*DESCRIBED).values.filter_map { |held| held["result"] }.flat_map do |result|
      result.is_a?(Array) ? result.map { |scene| "[#{scene['at']}] #{scene['caption']}" } : [ result.to_s ]
    end.compact_blank
  end

  def summary
    step_result("summary").to_h["summary"].presence
  end

  def tags
    summary_terms("tags")
      .select { |word| Feed.fit_tag?(word, feed) }
      .uniq(&:downcase)
  end

  def summary_terms(key)
    Array(step_result("summary").to_h[key]).filter_map { |word| word.to_s.strip.presence }
  end

  def turn!(resource:, role:, model:, number:, request:, content: nil, calls: [],
            error: nil, started_at: nil)
    entry = {
      "n" => number,
      "resource" => resource.respond_to?(:key) ? resource.key : resource.to_s,
      "role" => role.to_s,
      "model" => model.to_s,
      "request" => request.to_s.truncate(MAX_REQUEST),
      "calls" => Array(calls),
      "at" => Time.current.iso8601(3)
    }

    entry["content"] = content.to_s.truncate(MAX_RESPONSE) if content.present?
    entry["error"] = Redaction.scrub(error) if error.present?
    entry["ms"] = ((Time.current - started_at) * 1000).round if started_at

    append_column!(:turns, [ self.class.storable(entry) ])
    entry
  end

  def log_info(*parts) = line("[i]", *parts)
  def log_done(*parts) = line("[✓]", *parts)
  def log_skip(*parts) = line("[-]", *parts)
  def log_fail(*parts) = line("[x]", *parts)

  def line(*parts)
    text = Redaction.scrub(parts.compact.map { |part| part.to_s.tr("\n", " ") }.join(" : ")).truncate(LINE_LIMIT)

    emit(text)
  end

  def self.storable(value)
    case value
    when String then value.dup.force_encoding(Encoding::UTF_8).scrub.gsub("\u0000", "")
    when Array then value.map { |held| storable(held) }
    when Hash then value.to_h { |key, held| [ storable(key.to_s), storable(held) ] }
    else value
    end
  end

  private

    def remember_who_asked
      asking = Current.grant
      self.requested_by ||= asking.subject if asking && !asking.agent?
    end

    def merge_column!(column, value)
      Analysis.where(id: id).update_all(
        Analysis.sanitize_sql_array(
          [ "#{column} = #{column} || ?::jsonb, updated_at = now()", value.to_json ]
        )
      )
    end

    def append_column!(column, value)
      merge_column!(column, value)
    end

    def emit(text)
      index = append(text)
      return if index.nil?

      self.lines = index
      clear_attribute_changes([ :lines ])

      publish!
      index
    end

    def publish!
      XixoSchema.subscriptions.trigger(:analysis_progressed, { id: id.to_s }, self,
                                       scope: tenant_id)
      XixoSchema.subscriptions.trigger(:analysis_progressed, {}, self, scope: tenant_id)
    rescue StandardError => e
      Rails.logger.warn "analysis #{id} could not announce: #{e.message}"
    end

    def append(text)
      Analysis.with_connection do |connection|
        connection.select_value(
          Analysis.sanitize_sql_array(
            [ <<~SQL.squish, { line: "#{text}\n", limit: LOG_LIMIT, id: id } ]
              UPDATE analyses
                 SET logs = CASE WHEN length(coalesce(logs, '')) > :limit
                                 THEN logs
                                 ELSE coalesce(logs, '') || :line
                            END,
                     lines = lines + 1,
                     updated_at = now()
               WHERE id = :id
              RETURNING lines
            SQL
          )
        )
      end
    end

    def current_status
      Analysis.where(id: id).pick(:status)
    end

    def held_deadline
      return deadline unless persisted?

      self.deadline = Analysis.where(id: id).pick(:deadline)
      clear_attribute_changes(%i[deadline])
      deadline
    end
end
