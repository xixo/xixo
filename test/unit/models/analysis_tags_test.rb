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

      assert_equal [ "winter", "Black dog" ], analysis.tags
    end
  end

  test "amounts, dates, numbers and addresses are not tags" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "statement.pdf")
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analysis.write_step!("summary", {
        "result" => {
          "tags" => [ "Mortgage_Statement", "December 31, 2023", "9413527.1", "Form 1099-INT", "Q3 report" ],
          "entities" => [ "$2,409.33", "Jennifer Korn", "P.O. Box 351 STN C", "Toronto ON M6P 4H5", "MCAP" ]
        }
      })

      assert_equal [ "Mortgage_Statement", "Form 1099-INT", "Q3 report" ], analysis.tags
    end
  end

  test "a finished analysis files its feed under its tags, reusing a tag whatever its case" do
    Tenant.switch(@tenant) do
      acme = Feed.tag!("Acme")
      feed = Feed.create!(type: Feed::FILE, key: "scan.pdf")

      summarized(feed, tags: [ "invoice", "ACME" ])

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

  test "a tag's name reads underscores as spaces, whoever gives it" do
    Tenant.switch(@tenant) do
      assert_equal Feed.tag!("Mortgage Statement"), Feed.tag!("mortgage_statement")
      assert_equal "Single sign on", Feed.tag!("Single_sign_on").key
    end
  end

  test "a model number is a tag, and a file's own name, a date, or a number is not" do
    Tenant.switch(@tenant) do
      photo = Feed.create!(type: Feed::FILE, key: "GIG_2081.xmp")
      invoice = Feed.create!(type: Feed::FILE, key: "invoice.pdf")

      assert Feed.fit_tag?("NEMA 14-50R", photo)
      assert Feed.fit_tag?("UTF-16", photo)
      assert Feed.fit_tag?("invoice", invoice)
      assert_not Feed.fit_tag?("GIG 2081 file", photo)
      assert_not Feed.fit_tag?("GIG_2081.xmp", photo)
      assert_not Feed.fit_tag?("1966", photo)
      assert_not Feed.fit_tag?("June 2026", photo)
      assert_not Feed.fit_tag?("2 January 2024", photo)
      assert_not Feed.fit_tag?("2024-01-02", photo)
      assert_not Feed.fit_tag?("priya@orchardlane.invalid", photo)
      assert_not Feed.fit_tag?("orchardlane.invalid", photo)
      assert_not Feed.fit_tag?("resource:places", photo)
      assert_not Feed.fit_tag?("Feed27", photo)
      assert Feed.fit_tag?("Kilner Square Clip Top", photo)
    end
  end

  test "the agent is refused a tag that is the file's own name, and told what a tag is" do
    Tenant.switch(@tenant) do
      photo = Feed.create!(type: Feed::FILE, key: "GIG_2081.NEF")

      said = Current.set(grant: photo.grant, acting_for: photo.id) do
        Tool::Connect.call(a: photo.id.to_s, tag: "GIG 2081", server_context: {})
      end

      assert said.error?
      assert_match(/never the file's own name/, said.content.first[:text])
      assert_empty photo.tags
    end
  end

  test "a tag nothing is filed under any more is gone" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "scan.pdf")
      other = Feed.create!(type: Feed::FILE, key: "other.pdf")
      summarized(feed, tags: %w[invoice draft])
      other.connect!(Feed.tag!("invoice"))

      summarized(feed, tags: [ "paid" ])

      assert_equal %w[invoice paid], Feed.tags.order(:key).pluck(:key)
    end
  end

  test "an item's tags come most shared first" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "scan.pdf")
      summarized(feed, tags: %w[acme invoice oddity])
      2.times { |index| Feed.create!(type: Feed::FILE, key: "#{index}.pdf").connect!(Feed.tag!("invoice")) }
      Feed.create!(type: Feed::FILE, key: "x.pdf").connect!(Feed.tag!("acme"))

      assert_equal %w[invoice acme oddity], feed.tags.by_use.pluck(:key)
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

  def summarized(feed, tags: [], entities: [])
    analysis = Analysis.open!(feed: feed, cause: "manual")
    analysis.write_step!("summary", { "result" => { "summary" => "A scan.", "tags" => tags, "entities" => entities } })
    analysis.finished!
    analysis
  end
end
