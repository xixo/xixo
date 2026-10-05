require "test_helper"

class SummarizeUnsummarizedJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(subdomain: "unsum-#{SecureRandom.hex(4)}", name: "Unsummarized")
  end

  def analyzed(feed, summary: nil)
    analysis = Analysis.open!(feed: feed, cause: "sync")
    analysis.write_step!("summary", { "result" => { "summary" => summary } }) if summary
    analysis.finished!
    feed.references.each { |held| held.update_columns(analyzed_at: Time.current) }
    feed
  end

  def inference!
    Resource::OpenaiCompatible.create!(
      key: "ollama", details: { "base_url" => "http://127.0.0.1:1", "models" => { "smart" => "qwen3:8b" } }
    )
  end

  test "a file analyzed before there was a model is analyzed again once one arrives" do
    Tenant.switch(@tenant) do
      missed = analyzed(create_feed(key: "GIG_2125.NEF", locator_key: "GIG_2125.NEF"))
      told = analyzed(create_feed(key: "dentist.ics", locator_key: "dentist.ics"), summary: "A cleaning.")
      pending = create_feed(key: "new.txt", locator_key: "new.txt")

      assert_equal [ missed.id ], Feed.unsummarized.pluck(:id)
      assert_not_includes Feed.unsummarized, told
      assert_not_includes Feed.unsummarized, pending

      assert_enqueued_jobs 1, only: SummarizeUnsummarizedJob do
        inference!
      end

      assert_enqueued_jobs 1, only: AnalyzeFeedJob do
        SummarizeUnsummarizedJob.perform_now
      end

      assert_empty Feed.unsummarized, "a file already being analyzed again is not queued twice"
    end
  end

  test "a model resource that only checks in does not reanalyze anything" do
    Tenant.switch(@tenant) do
      held = inference!

      assert_no_enqueued_jobs only: SummarizeUnsummarizedJob do
        held.update!(checked_at: Time.current)
      end
    end
  end
end
