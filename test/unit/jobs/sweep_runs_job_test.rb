require "test_helper"

class SweepRunsJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "sweep-#{SecureRandom.hex(4)}", name: "Sweep")
    @other = Tenant.create!(subdomain: "sweep-#{SecureRandom.hex(4)}", name: "Elsewhere")
  end

  def run_finished(tenant, status:, at:)
    Tenant.switch(tenant) do
      run = Run.start!(kind: "sync", selector: { "id" => 1 })
      run.update_columns(status: status, finished_at: at)
      run
    end
  end

  test "a run that finished before the cutoff is swept" do
    stale = run_finished(@tenant, status: "done", at: 30.days.ago)
    recent = run_finished(@tenant, status: "done", at: 1.day.ago)

    SweepRunsJob.perform_now

    Tenant.switch(@tenant) do
      assert_nil Run.find_by(id: stale.id)
      assert Run.find_by(id: recent.id).present?
    end
  end

  test "a run still open is left alone however old it looks" do
    open = run_finished(@tenant, status: "queued", at: 30.days.ago)

    SweepRunsJob.perform_now

    Tenant.switch(@tenant) { assert Run.find_by(id: open.id).present? }
  end

  test "a failed run is swept like any other closed one, so nothing grows forever" do
    failed = run_finished(@tenant, status: "failed", at: 30.days.ago)

    SweepRunsJob.perform_now

    Tenant.switch(@tenant) { assert_nil Run.find_by(id: failed.id) }
  end

  test "sweeping reaches every tenant rather than the one that happened to be current" do
    mine = run_finished(@tenant, status: "done", at: 30.days.ago)
    theirs = run_finished(@other, status: "done", at: 30.days.ago)

    SweepRunsJob.perform_now

    Tenant.switch(@tenant) { assert_nil Run.find_by(id: mine.id) }
    Tenant.switch(@other) { assert_nil Run.find_by(id: theirs.id) }
  end

  test "a retention of zero sweeps nothing" do
    kept = run_finished(@tenant, status: "done", at: 30.days.ago)

    with_retention(0) { SweepRunsJob.perform_now }

    Tenant.switch(@tenant) { assert Run.find_by(id: kept.id).present? }
  end

  test "an open run still inside its deadline is left running" do
    working = Tenant.switch(@tenant) do
      Run.start!(kind: "sync", deadline: 1.hour.from_now).tap { |run| run.running! }
    end

    SweepRunsJob.perform_now

    Tenant.switch(@tenant) { assert_equal "running", working.reload.status }
  end

  test "a run with no deadline at all is never reaped" do
    forever = Tenant.switch(@tenant) { Run.start!(kind: "sync", deadline: nil) }

    Tenant.switch(@tenant) { forever.update_columns(deadline: nil) }

    SweepRunsJob.perform_now

    Tenant.switch(@tenant) { assert_equal "queued", forever.reload.status }
  end

  test "a run is given a deadline by default, so none can strand" do
    Tenant.switch(@tenant) do
      assert_in_delta Rails.configuration.uris.run_deadline.from_now,
                      Run.start!(kind: "sync").deadline, 5
    end
  end

  private

    def with_retention(days)
      previous = Rails.configuration.uris.run_retention
      Rails.configuration.uris.run_retention = days.days
      yield
    ensure
      Rails.configuration.uris.run_retention = previous
    end
end
