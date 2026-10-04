require "test_helper"

class FailurePolicyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(subdomain: "fail-#{SecureRandom.hex(4)}", name: "Failures")
    @bucket = "test-#{SecureRandom.hex(6)}"

    Tenant.switch(@tenant) do
      @reachable = Resource::S3.create!(key: @bucket, name: "Reachable", details: s3_details, credentials: s3_credentials)
      @unreachable = Resource::S3.create!(key: "gone", name: "Unreachable",
                                          details: { "endpoint" => "http://127.0.0.1:1" },
                                          credentials: s3_credentials)
    end

    @reachable.client.create_bucket(bucket: @bucket)
    @reachable.client.put_object(bucket: @bucket, key: "broken.pdf", body: "not a pdf")

    Tenant.switch(@tenant) do
      @broken = Reference.discover!(resource: @reachable, locator: { "bucket" => @bucket, "key" => "broken.pdf" },
                                         locator_key: "broken.pdf", mime: "application/pdf", title: "broken.pdf").feed
      @stranded = create_feed(mime: "text/plain", title: "stranded.txt", locator_key: "stranded.txt",
                               resource: @unreachable, locator: { "bucket" => "gone", "key" => "stranded.txt" })
    end
  end

  teardown do
    @reachable.client.delete_object(bucket: @bucket, key: "broken.pdf")
    @reachable.client.delete_bucket(bucket: @bucket)
  rescue Aws::S3::Errors::NoSuchBucket
    nil
  end

  test "a file the analyzer cannot read is discarded, not retried forever" do
    assert_no_enqueued_jobs do
      assert_nothing_raised { Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, @broken.id) } }
    end

    Tenant.switch(@tenant) do
      assert_equal "Analyzer::Failed",
                   @broken.reload.analysis.step("info").dig("error", "class")
      assert_not_nil @broken.references.first.reload.analyzed_at
    end
  end

  test "the same failure point retries when the resource is what broke" do
    assert_enqueued_jobs 1, only: AnalyzeFeedJob do
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, @stranded.id) }
    end
  end

  test "an unreachable resource raises the retryable error, not a vendor one" do
    Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { @unreachable.command("list") }
    end
  end

  test "a malformed command is an argument error, which no policy retries" do
    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { @reachable.command("rm", key: "x") }
      assert_raises(ArgumentError) { @reachable.command("get") }
    end
  end

  test "analysis is capped per tenant, so one cannot occupy the pool" do
    assert_equal 2, AnalyzeFeedJob.concurrency_limit
    assert_equal "AnalyzeFeedJob/analysis/#{@tenant.id}",
                 AnalyzeFeedJob.new(@tenant.id, @broken.id).concurrency_key
  end

  test "analysis and the iterators do not share a queue" do
    assert_equal "analysis", AnalyzeFeedJob.new.queue_name
    assert_equal "sync", SyncResourceJob.new.queue_name
    assert_equal "export", ExportItemsJob.new.queue_name
  end

  private

    def s3_details
      { "endpoint" => ENV.fetch("S3_ENDPOINT", "http://127.0.0.1:9000"),
        "region" => ENV.fetch("S3_REGION", "us-east-1") }
    end

    def s3_credentials
      { "access_key_id" => ENV.fetch("S3_ACCESS_KEY_ID", "items"),
        "secret_access_key" => ENV.fetch("S3_SECRET_ACCESS_KEY", "xixoxixo") }
    end
end
