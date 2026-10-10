require "test_helper"

class ScheduleChecksJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(subdomain: "checks-#{SecureRandom.hex(4)}", name: "Checked")
    @other = Tenant.create!(subdomain: "checks-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) { @curl = Resource::Curl.create!(key: "curl", name: "Curl") }
    Tenant.switch(@other) { @theirs = Resource::Curl.create!(key: "curl", name: "Theirs") }
  end

  test "a resource never checked, or not checked for a while, is checked in every tenant" do
    Tenant.switch(@other) { @theirs.update_columns(checked_at: (Resource::CHECKED_EVERY + 1.minute).ago) }

    perform_enqueued_jobs { ScheduleChecksJob.perform_now }

    Tenant.switch(@tenant) { assert_in_delta Time.current, @curl.reload.checked_at, 5 }
    Tenant.switch(@other) { assert_in_delta Time.current, @theirs.reload.checked_at, 5 }
  end

  test "a resource checked recently is left alone" do
    Tenant.switch(@tenant) { @curl.update_columns(checked_at: 1.hour.ago) }

    Tenant.switch(@other) { @theirs.update_columns(checked_at: 1.hour.ago) }

    assert_no_enqueued_jobs(only: CheckResourceJob) { ScheduleChecksJob.perform_now }
  end

  test "a resource whose last check failed is checked again within minutes" do
    Tenant.switch(@tenant) do
      @curl.update_columns(checked_at: (Resource::FAILING_CHECKED_EVERY + 1.minute).ago, check_error: "Resource::Failed: off")
    end
    Tenant.switch(@other) { @theirs.update_columns(checked_at: 1.minute.ago, check_error: "Resource::Failed: off") }

    assert_enqueued_jobs(1, only: CheckResourceJob) { ScheduleChecksJob.perform_now }
  end

  test "what a check finds wrong is written down, so a failing resource shows before a sync meets it" do
    Tenant.switch(@tenant) do
      @broken = Resource::Rss.create!(key: "feed", name: "Feed", details: { "url" => "http://169.254.169.254/feed" })
    end

    perform_enqueued_jobs { ScheduleChecksJob.perform_now }

    Tenant.switch(@tenant) { assert_match(/not a public address/, @broken.reload.check_error) }
  end

  test "a resource that is syncing, put away, or kept by xixo for itself is not checked" do
    Tenant.switch(@tenant) do
      @curl.update_columns(archived_at: Time.current)
      Resource.internal!(:children)
      syncing = Resource::Database.create!(key: "database", name: "Storage")
      syncing.claim_sync!

      assert_empty Resource.due_for_check
    end
  end

  test "a check queued before a recent one ran does not run twice" do
    Tenant.switch(@tenant) do
      CheckResourceJob.perform_now(@curl.id)
      checked = @curl.reload.checked_at

      travel 1.minute
      CheckResourceJob.perform_now(@curl.id)

      assert_equal checked, @curl.reload.checked_at
    end
  end
end
