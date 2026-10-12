require "test_helper"

class DerivedImagesTest < ActiveSupport::TestCase
  FILES = Rails.root.join("test/fixtures/files")

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "derive-#{SecureRandom.hex(4)}", name: "Derived")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "disk", name: "Storage")
      @storage.make_default_storage!
    end
  end

  test "a pass renders the thumbnail and the preview once and keeps them as references" do
    Tenant.switch(@tenant) do
      feed = staged("sign.png")
      pass(feed)

      thumbnail = feed.references.in_role(Reference::THUMBNAIL).sole
      preview = feed.references.in_role(Reference::PREVIEW).sole

      assert_equal Resource.internal!(:derived), thumbnail.resource
      assert_equal "\xFF\xD8".b, thumbnail.download.read.byteslice(0, 2)
      assert_equal Reference::RENDERED_AS, preview.mime
      assert_equal({ "thumbnail" => "#{feed.id}/thumbnail.jpg", "preview" => "#{feed.id}/preview.jpg" },
                   feed.analysis.step_result("derived"))
    end
  end

  test "the derived images never stand in for the original" do
    Tenant.switch(@tenant) do
      feed = staged("sign.png")
      pass(feed)
      Placement.new(feed).settled!

      assert_equal Reference::ORIGINAL, feed.reload.reference.role
      assert_equal "image/png", feed.mime
      assert_equal @storage, feed.resource
    end
  end

  test "a second pass over the same bytes reads the images it already made" do
    Tenant.switch(@tenant) do
      feed = staged("sign.png")
      pass(feed)
      Placement.new(feed).settled!

      assert_no_changes -> { feed.references.in_role(Reference::THUMBNAIL).sole.updated_at } do
        pass(feed.reload)
      end
    end
  end

  test "a changed size reads the file again with the new settings" do
    Tenant.switch(@tenant) do
      feed = staged("poster.png")
      pass(feed)

      Setting.write!("hires_size", "1024", subject: nil)
      Setting.write!("thumbnail_size", "160", subject: nil)
      pass(feed.reload)

      assert_equal 2, FakeLink.asked.size
      assert_equal({ "thumbnail" => 160, "preview" => 1024 }, FakeLink.asked.last.args["settings"].slice("thumbnail", "preview"))
      assert_equal 1, feed.references.in_role(Reference::PREVIEW).count
    end
  end

  test "an animation's frames are kept in order, and a pass with fewer leaves none behind" do
    Tenant.switch(@tenant) do
      feed = staged("animated.gif")
      FakeLink.script = ->(*) { FakeLink.extracted({ "frames" => 3 }, files: framed(3), extractor: "image") }
      pass(feed)

      assert_equal [ 0.0, 0.5, 1.0 ], feed.references.in_role(Reference::FRAME).map { |held| held.locator["at"] }.sort

      Setting.write!("animation_frames", "2", subject: nil)
      FakeLink.script = ->(*) { FakeLink.extracted({ "frames" => 3 }, files: framed(2), extractor: "image") }
      pass(feed.reload)

      assert_equal 2, feed.references.in_role(Reference::FRAME).count
      assert_equal 2, Resource.internal!(:derived).blobs.where("key LIKE ?", "#{feed.id}/frame-%").count
    end
  end

  test "forgetting the feed takes the derived bytes with it" do
    Tenant.switch(@tenant) do
      feed = staged("sign.png")
      pass(feed)
      store = Resource.internal!(:derived)

      assert_difference -> { store.blobs.count }, -2 do
        feed.destroy!
      end
    end
  end

  test "forgetting a message takes the attachments xixo extracted from it" do
    Tenant.switch(@tenant) do
      store = Resource.internal!(:children)
      message = Feed.create!(type: Feed::FILE, key: "march.eml", title: "march.eml")
      attachment = Feed.create!(type: Feed::FILE, key: "invoice.pdf", title: "invoice.pdf", parent: message)
      key = "#{message.id}/0/0/invoice.pdf"
      Reference.record!(feed: attachment, resource: store, locator: store.upload(key, "pdf bytes"),
                        locator_key: key)

      assert_difference -> { store.blobs.count }, -1 do
        message.destroy!
      end
    end
  end

  test "a resource someone attaches cannot take the key of a store xixo keeps for itself" do
    Tenant.switch(@tenant) do
      squatter = Resource::S3.new(key: "derived", details: { "endpoint" => "http://x" })

      assert_not squatter.valid?
      assert_match(/kept for a store xixo makes/, squatter.errors[:key].join)
      assert Resource.internal!(:derived).internal?
    end
  end

  test "a place the app keeps for itself is never offered for a file" do
    Tenant.switch(@tenant) do
      Resource.internal!(:derived)
      Resource.internal!(:children)

      assert_equal [ "disk" ], Resource.placeable("image/png", size: 10).pluck(:key)
    end
  end

  private

    def staged(name)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Staged.stage!(feed, path: name, body: FILES.join(name).binread, mime: MimeType.for_filename(name))
      feed
    end

    def pass(feed)
      analysis = Analysis.open!(feed: feed, cause: "upload")
      Analyzer.for(feed, analysis: analysis).run
      analysis.finished!
      analysis
    end

    def framed(count)
      Array.new(count) { |index| { role: "frame", name: "frame-#{index}.jpg", at: index * 0.5 } }
    end
end
