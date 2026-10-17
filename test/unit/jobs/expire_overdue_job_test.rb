require "test_helper"

class ExpireOverdueJobTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "overdue-#{SecureRandom.hex(4)}", name: "Overdue")
    @other = Tenant.create!(subdomain: "overdue-#{SecureRandom.hex(4)}", name: "Elsewhere")
  end

  def opened(tenant, deadline:, status: "running")
    Tenant.switch(tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "stuck.pdf", title: "stuck.pdf")
      Analysis.open!(feed: feed, cause: "sync").tap do |analysis|
        analysis.update_columns(status: status, deadline: deadline)
      end
    end
  end

  test "an analysis whose job died is closed once its deadline passes, in every tenant" do
    mine = opened(@tenant, deadline: 1.minute.ago)
    theirs = opened(@other, deadline: 1.minute.ago)

    ExpireOverdueJob.perform_now

    Tenant.switch(@tenant) { assert_equal [ "cancelled", "deadline passed" ], mine.reload.values_at(:status, :error) }
    Tenant.switch(@other) { assert_equal "cancelled", theirs.reload.status }
  end

  test "an analysis still waiting in the queue is never expired, however long the queue is" do
    waiting = opened(@tenant, deadline: 1.minute.ago, status: "queued")

    ExpireOverdueJob.perform_now

    Tenant.switch(@tenant) { assert_equal "queued", waiting.reload.status }
  end

  test "an analysis still inside its deadline is left to finish" do
    live = opened(@tenant, deadline: 1.hour.from_now)

    ExpireOverdueJob.perform_now

    Tenant.switch(@tenant) { assert_equal "running", live.reload.status }
  end

  test "a run past its deadline is closed the same way" do
    run = Tenant.switch(@tenant) do
      Run.start!(kind: "sync").tap { |held| held.update_columns(status: "running", deadline: 1.minute.ago) }
    end

    ExpireOverdueJob.perform_now

    Tenant.switch(@tenant) { assert_equal "cancelled", run.reload.status }
  end
end
