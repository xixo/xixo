class Run < ApplicationRecord
  include TenantScoped

  KINDS = %w[sync export reindex snapshot fetch].freeze
  STATUSES = %w[queued running done failed cancelled gated].freeze
  OPEN = %w[queued running].freeze

  belongs_to :resource, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  scope :open, -> { where(status: OPEN) }
  scope :newest_first, -> { order(id: :desc) }
  scope :past_deadline, -> { open.where(deadline: ...Time.current) }
  scope :visible_to, ->(grant) {
    where(resource_id: nil).or(where(resource_id: Resource.reachable_by(grant).select(:id)))
  }

  def self.start!(kind:, resource: nil, selector: {}, deadline: nil)
    create!(kind: kind, resource: resource, selector: selector.to_h,
            deadline: deadline || default_deadline)
  end

  def self.default_deadline
    budget = Rails.configuration.xixo.run_deadline

    budget.to_i.zero? ? nil : budget.from_now
  end

  def open?
    OPEN.include?(status)
  end

  def running!
    Run.where(id: id, status: OPEN)
       .update_all(status: "running", started_at: started_at || Time.current)
  end

  def progressed!(count)
    return if count.zero?

    Run.where(id: id).update_all("processed = processed + #{count.to_i}")
  end

  def finished!(error: nil)
    return if %w[cancelled gated].include?(current_status)

    update_columns(
      status: error ? "failed" : "done",
      error: error&.truncate(500),
      finished_at: Time.current
    )

    publish!
  end

  def gated!
    return false unless open?

    update_columns(status: "gated", finished_at: Time.current)
    publish!
    true
  end

  def cancel!
    return false unless open?

    update_columns(status: "cancelled", finished_at: Time.current)
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
    return false if deadline.nil?
    return false if Time.current < deadline

    update_columns(status: "cancelled", error: "deadline passed", finished_at: Time.current)
    true
  end

  LOG_LIMIT = 256_000
  LINE_LIMIT = 2_000

  def log_info(*parts) = line("[i]", *parts)
  def log_done(*parts) = line("[✓]", *parts)
  def log_skip(*parts) = line("[-]", *parts)
  def log_fail(*parts) = line("[x]", *parts)

  # Appends in SQL rather than read-modify-write so the returned index is the
  # authoritative position of this line, and a second writer cannot lose one.
  def line(*parts)
    text = parts.compact.map { |part| part.to_s.tr("\n", " ") }.join(" : ").truncate(LINE_LIMIT)

    emit(text)
  end

  private

    def emit(text)
      index = append(text)
      return if index.nil?

      self.lines = index
      clear_attribute_changes([ :lines ])

      publish!
      index
    end

    def publish!
      XixoSchema.subscriptions.trigger(:run_progressed, { id: id.to_s }, self, scope: tenant_id)
      XixoSchema.subscriptions.trigger(:run_progressed, {}, self, scope: tenant_id)
    rescue StandardError => e
      Rails.logger.warn "run #{id} could not announce: #{e.message}"
    end

    def append(text)
      Run.with_connection do |connection|
        connection.select_value(
          Run.sanitize_sql_array([ <<~SQL.squish, { line: "#{text}\n", limit: LOG_LIMIT, id: id } ])
            UPDATE runs
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
      end
    end


    def current_status
      Run.where(id: id).pick(:status)
    end
end
