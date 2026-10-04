require "test_helper"

class ResourceServingTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "serve-#{SecureRandom.hex(4)}", name: "Serving")
  end

  def s3(key = "bucket")
    Resource::S3.create!(key: key, details: { "endpoint" => "http://127.0.0.1:1" })
  end

  test "a type declares what it serves rather than answering a method about it" do
    assert_equal [ :storage ], Resource::S3.capabilities
    assert_equal [ "*/*" ], Resource::S3.accepts
    assert_nil Resource::S3.up_to

    assert_equal [ :inference ], Resource::OpenaiCompatible.capabilities
    assert_empty Resource::OpenaiCompatible.accepts

    assert_empty Resource::Rss.capabilities, "a feed is read, not written to"
  end

  test "what a type serves is mirrored onto the row when it is saved" do
    Tenant.switch(@tenant) do
      held = s3

      assert_equal({ "capabilities" => [ "storage" ], "accepts" => [ "*/*" ] }, held.serving)
    end
  end

  test "a ceiling is mirrored too, in bytes" do
    Tenant.switch(@tenant) do
      held = Resource::Database.create!(key: "blobs")

      assert_equal 64.megabytes, held.serving["up_to"]
      assert_equal 64.megabytes, held.up_to
    end
  end

  test "capable_of is a query rather than every resource loaded and asked" do
    Tenant.switch(@tenant) do
      bucket = s3
      Resource::Rss.create!(key: "feed", details: { "url" => "https://example.test/feed.xml" })

      found = Resource.capable_of(:storage)

      assert_kind_of ActiveRecord::Relation, found
      assert_equal [ bucket.id ], found.ids
      assert_empty Resource.capable_of(:browser)
    end
  end

  test "an archived resource serves nothing" do
    Tenant.switch(@tenant) do
      bucket = s3
      bucket.update!(archived_at: Time.current)

      assert_empty Resource.capable_of(:storage)
      assert_empty Resource.accepting("application/pdf")
    end
  end

  test "accepting matches a pattern against a mime, in the database" do
    Tenant.switch(@tenant) do
      bucket = s3

      assert_equal [ bucket.id ], Resource.accepting("video/mp4").ids
      assert_equal [ bucket.id ], Resource.accepting("application/pdf").ids
    end
  end

  test "a narrower pattern takes only what it names" do
    Tenant.switch(@tenant) do
      bucket = s3
      bucket.update_columns(serving: bucket.serving.merge("accepts" => [ "image/*" ]))

      assert_equal [ bucket.id ], Resource.accepting("image/png").ids
      assert_empty Resource.accepting("application/pdf")
    end
  end

  test "a ceiling is what answers which resources accept a four gigabyte video" do
    Tenant.switch(@tenant) do
      bucket = s3
      blobs = Resource::Database.create!(key: "blobs")

      small = Resource.accepting("video/mp4", size: 2.megabytes).ids

      assert_equal [ bucket.id, blobs.id ].sort, small.sort

      assert_equal [ bucket.id ], Resource.accepting("video/mp4", size: 4.gigabytes).ids
    end
  end

  test "a resource answers for itself the way the query does" do
    Tenant.switch(@tenant) do
      blobs = Resource::Database.create!(key: "blobs")

      assert blobs.accepts?("video/mp4", size: 2.megabytes)
      assert_not blobs.accepts?("video/mp4", size: 4.gigabytes)
      assert blobs.accepts?("video/mp4"), "no size asked is no size refused"

      Resource::Rss.create!(key: "feed", details: { "url" => "https://example.test/feed.xml" })
                   .then { |feed| assert_not feed.accepts?("text/plain") }
    end
  end

  test "restate! brings a row written before a declaration changed back into step" do
    Tenant.switch(@tenant) do
      bucket = s3
      bucket.update_columns(serving: {})

      assert_empty Resource.capable_of(:storage), "the row is what the query reads"

      Resource.restate!

      assert_equal [ bucket.id ], Resource.capable_of(:storage).ids
    end
  end

  test "restate! outside a tenant reaches no row, so boot restates inside each one" do
    bucket = Tenant.switch(@tenant) { s3.tap { |held| held.update_columns(serving: {}) } }

    Resource.restate!

    Tenant.switch(@tenant) { assert_equal({}, bucket.reload.serving) }

    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("xixo:resources")
    Rake::Task["xixo:resources"].reenable
    capture_io { Rake::Task["xixo:resources"].invoke }

    Tenant.switch(@tenant) { assert_equal [ bucket.id ], Resource.capable_of(:storage).ids }
  end

  test "describe carries what it accepts, which is what an agent reads" do
    Tenant.switch(@tenant) do
      described = Resource::Database.create!(key: "blobs").describe

      assert_equal [ :storage ], described[:capabilities]
      assert_equal [ "*/*" ], described[:accepts]
      assert_equal 64.megabytes, described[:up_to]
    end
  end
end
