require "test_helper"

class AnalysisTagsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(subdomain: "tags-#{SecureRandom.hex(4)}", name: "Tags")
  end

  test "the file's own name and stray characters read off it are not tags" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "GIG_1960.NEF", title: "GIG_1960.NEF")
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analysis.write_step!("summary", {
        "result" => {
          "summary" => "A family on a frozen lake.",
          "tags" => [ "winter", "Black dog", "GIG_1960.NEF" ],
          "entities" => [ "GIG_1960.NEF", "7", "a", "black dog", "D750" ]
        }
      })

      assert_equal [ "winter", "Black dog", "D750" ], analysis.tags
    end
  end

  test "a finished analysis files its feed under its tags, reusing a tag whatever its case" do
    Tenant.switch(@tenant) do
      acme = Feed.tag!("Acme")
      feed = Feed.create!(type: Feed::FILE, key: "scan.pdf")

      summarized(feed, tags: [ "invoice" ], entities: [ "ACME" ])

      assert_equal %w[Acme invoice], feed.tags.order(:key).pluck(:key)
      assert_equal [ acme.id ], Feed.tags.where("lower(key) = 'acme'").pluck(:id)
      assert feed.edges.all?(&:inferred)
    end
  end

  test "a new analysis replaces the tags the last one found and leaves the ones a person chose" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "scan.pdf")
      summarized(feed, tags: %w[invoice draft])
      feed.connect!(Feed.tag!("taxes"))
      feed.connect!(Feed.tag!("draft"))

      summarized(feed, tags: %w[invoice paid])

      assert_equal %w[draft invoice paid taxes], feed.tags.order(:key).pluck(:key)
      assert_equal %w[invoice paid], feed.tags.where(id: feed.edges.inferred.select(:a_id))
                                             .or(feed.tags.where(id: feed.edges.inferred.select(:b_id)))
                                             .order(:key).pluck(:key)
    end
  end

  test "a failed analysis keeps the tags the feed had" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "scan.pdf")
      summarized(feed, tags: [ "invoice" ])

      Analysis.open!(feed: feed, cause: "manual").finished!(error: "the model is asleep")

      assert_equal [ "invoice" ], feed.tags.pluck(:key)
    end
  end

  test "a feed that takes another's place takes its tags, still marked as found by analysis" do
    Tenant.switch(@tenant) do
      kept = Feed.create!(type: Feed::FILE, key: "a.pdf")
      other = Feed.create!(type: Feed::FILE, key: "b.pdf")
      summarized(other, tags: [ "invoice" ])
      other.connect!(Feed.tag!("taxes"))

      kept.inherit!(other)

      assert_equal({ "invoice" => true, "taxes" => false },
                   kept.edges.to_h { |edge| [ edge.other_than(kept).key, edge.inferred ] })
    end
  end

  test "the tags are found again by analyzing every file and note in every tenant" do
    RetagFeedsJob.perform_now

    enqueued = enqueued_jobs.select { |job| job["job_class"] == "AnalyzeFeedsJob" }
    ours = enqueued.find { |job| job["arguments"].first == @tenant.id }

    assert_equal Tenant.count, enqueued.size
    assert_equal @tenant.subdomain, ours["tenant"]
    assert_equal [ Feed::FILE, Feed::NOTE ], ours["arguments"].second["type"]
  end

  def summarized(feed, tags: [], entities: [])
    analysis = Analysis.open!(feed: feed, cause: "manual")
    analysis.write_step!("summary", { "result" => { "summary" => "A scan.", "tags" => tags, "entities" => entities } })
    analysis.finished!
    analysis
  end
end
