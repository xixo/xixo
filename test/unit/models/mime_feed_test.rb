require "test_helper"

class MimeFeedTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "mime-#{SecureRandom.hex(4)}", name: "Mimes")
  end

  test "a content type is minted once and reused" do
    Tenant.switch(@tenant) do
      one = Feed.mime!("application/pdf")
      two = Feed.mime!("application/pdf")

      assert_equal one, two
      assert_equal Feed::MIME, one.type
      assert_equal "application/pdf", one.title
      assert_equal 1, Feed.mimes.count
    end
  end

  test "a mime and a tag of the same key are two rows, because the singleton is per type" do
    Tenant.switch(@tenant) do
      mime = Feed.mime!("text/markdown")
      tag = Feed.tag!("text/markdown")

      assert_not_equal mime.id, tag.id
      assert mime.mime?
      assert tag.tag?
    end
  end

  test "the database refuses a second row for the same content type" do
    Tenant.switch(@tenant) do
      Feed.mime!("image/png")

      assert_raises ActiveRecord::RecordNotUnique do
        Feed.transaction(requires_new: true) do
          Feed.insert_all!([ { tenant_id: @tenant.id, type: Feed::MIME, key: "image/png",
                               origin: "resource", created_at: Time.current,
                               updated_at: Time.current } ])
        end
      end

      assert_equal 1, Feed.mimes.count, "the duplicate never landed"
    end
  end

  test "filing a feed under a content type leaves its tags alone" do
    Tenant.switch(@tenant) do
      feed = create_feed(mime: "application/pdf", title: "invoice.pdf", locator_key: "invoice.pdf")
      feed.connect!(Feed.mime!("application/pdf"))
      feed.connect!(Feed.tag!("invoices"))

      assert_equal [ "application/pdf" ], feed.mimes.map(&:key)
      assert_equal [ "invoices" ], feed.tags.map(&:key)
      assert_equal 2, feed.connected.count
    end
  end

  test "destroying a content type takes its edges and leaves what it held" do
    Tenant.switch(@tenant) do
      feed = create_feed(mime: "application/pdf", title: "invoice.pdf", locator_key: "invoice.pdf")
      mime = Feed.mime!("application/pdf")
      feed.connect!(mime)

      mime.destroy!

      assert_equal 0, Edge.count
      assert Feed.exists?(feed.id)
    end
  end
end
