class Schedule < ApplicationRecord
  TURNS = 6
  MINIMUM_INTERVAL = 1.minute

  include TenantScoped

  belongs_to :feed

  validates :prompt, presence: true
  validates :feed_id, uniqueness: { scope: :tenant_id }
  validates :interval, numericality: { greater_than_or_equal_to: MINIMUM_INTERVAL.to_i },
                       allow_nil: true
  validate :only_an_address_runs_itself

  before_save :keep_next_run

  scope :running, -> { where.not(interval: nil).where(paused_at: nil) }
  scope :due, -> { running.where(next_run_at: ..Time.current) }

  def turns_allowed = turns.presence || TURNS

  def scheduled? = interval.present? && paused_at.nil?

  def paused? = paused_at.present?

  def pause! = update!(paused_at: Time.current)

  def resume! = update!(paused_at: nil)

  def run!
    update_columns(ran_at: Time.current)
    feed.analyze!(cause: "schedule").tap { schedule_next! }
  end

  def schedule_next!
    return unless scheduled?

    update_columns(next_run_at: Time.current + interval.seconds)
  end

  private

    def keep_next_run
      if !scheduled?
        self.next_run_at = nil
      elsif !next_run_at_changed? && (next_run_at.nil? || interval_changed?)
        self.next_run_at = Time.current + interval.seconds
      end
    end

    def only_an_address_runs_itself
      return if feed.nil? || feed.address?

      errors.add(:feed, "is not an address, so it has nothing to run")
    end
end
