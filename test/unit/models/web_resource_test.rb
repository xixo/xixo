require "test_helper"
require_relative "../../support/fake_feed_server"

class WebResourceTest < ActiveSupport::TestCase
  PAGE = <<~HTML.freeze
    <!doctype html>
    <html><head><title>A page about pelicans</title></head>
    <body style="margin:0"><h1>Pelicans</h1><p>Rather a lot about pelicans.</p></body></html>
  HTML

  CHANGED = <<~HTML.freeze
    <!doctype html>
    <html><head><title>A page about herons</title></head>
    <body style="margin:0"><h1>Herons</h1><p>Rather a lot about herons instead.</p></body></html>
  HTML

  setup do
    SearchIndex.reset!

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    @server = FakeFeedServer.current
    @server.reset!
    @url = @server.serve_body("/page.html", PAGE, content_type: "text/html")

    @tenant = Tenant.create!(subdomain: "web-#{SecureRandom.hex(4)}", name: "Snapshots")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "blobs", name: "Storage")
      @storage.make_default_storage!

      @resource = Resource::Web.create!(key: "web-#{SecureRandom.hex(4)}", name: "The web")
    end
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "a web resource cannot be scheduled, having nothing to enumerate yet" do
    Tenant.switch(@tenant) do
      refute @resource.syncable?

      @resource.sync_interval = 300

      refute @resource.valid?
      assert_match(/cannot sync/, @resource.errors.full_messages.to_sentence)
    end
  end

  # The manage UI hides syncing and scheduling on what cannot be synced, so it
  # has to be able to ask rather than infer it from the type.
  test "syncable is answered over graphql" do
    field = Types::ResourceType.fields["syncable"]

    assert field, "ResourceType should expose syncable"
    assert_equal "syncable?", field.method_sym.to_s

    Tenant.switch(@tenant) do
      refute @resource.syncable?, "a browser has nothing to enumerate"
      assert @storage.syncable?, "storage does"
    end
  end

  test "a tenant with no storage cannot snapshot, and says so" do
    Tenant.switch(@tenant) do
      @storage.update!(default_storage: false)

      error = assert_raises(Resource::Unusable) { @resource.storage }

      assert_match(/no storage to put a snapshot in/, error.message)
    end
  end

  test "the storage a snapshot names is the storage resource of that key, not another type sharing it" do
    Tenant.switch(@tenant) do
      Resource::Curl.create!(key: "keep")
      kept = Resource::Database.create!(key: "keep", name: "Kept")
      @resource.update!(details: @resource.details.merge("storage" => "keep"))

      assert_equal kept, @resource.storage
      assert_equal kept, @resource.send(:holding, { "storage" => "keep" })
      assert_equal kept, @resource.send(:holding, { "storage" => "keep", "storage_type" => kept.type })
    end
  end

  test "a snapshot kept in somebody's own storage is not read back from it" do
    Tenant.switch(@tenant) do
      Resource::Database.create!(key: "private", name: "Private", owner_subject: "ada")

      assert_equal @storage, @resource.send(:holding, { "storage" => "private" })
    end
  end

  test "a snapshot becomes an item of its own kind, keyed on the address" do
    rendering do
      reference = Tenant.switch(@tenant) { @resource.snapshot!(@url) }

      Tenant.switch(@tenant) do
        assert_equal 1, Feed.files.count
        assert_equal MimeType::PAGE, reference.feed.mime
        assert_equal "A page about pelicans", reference.feed.title
        assert_equal @url, reference.locator_key
        assert_equal @resource.id, reference.resource_id
      end
    end
  end

  test "the bytes go to storage and come back through the resource that took them" do
    rendering do
      Tenant.switch(@tenant) do
        reference = @resource.snapshot!(@url)

        assert_equal @storage.key, reference.locator["storage"]
        assert_equal 2, ResourceBlob.where(resource_id: @storage.id).count

        png = reference.download.read

        assert_equal "\x89PNG\r\n\x1A\n".b, png.byteslice(0, 8)
        assert_match(/Pelicans/, @resource.read(reference.locator))
      end
    end
  end

  test "snapshotting the same address again is a new version of one item, not a second" do
    rendering do
      Tenant.switch(@tenant) do
        first = @resource.snapshot!(@url)
        was = first.version

        @server.serve_body("/page.html", CHANGED, content_type: "text/html")
        again = @resource.snapshot!(@url)

        assert_equal 1, Feed.files.count
        assert_equal first.id, again.id
        refute_equal was, again.version
        assert again.changed_at.present?
        assert_nil again.analyzed_at
        assert_equal "A page about herons", again.feed.reload.title
      end
    end
  end

  test "a fragment is not a different page" do
    rendering do
      Tenant.switch(@tenant) do
        @resource.snapshot!("#{@url}#somewhere")
        @resource.snapshot!(@url)

        assert_equal 1, Feed.files.count
        assert_equal @url, Reference.first.locator_key
      end
    end
  end

  test "an address that was never snapshotted is gone rather than empty" do
    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Web::Gone) { @resource.command_get(url: @url) }

      assert_match(/nothing snapshotted/, error.message)
    end
  end

  test "the snapshot command answers with the item it made" do
    rendering do
      answer = Tenant.switch(@tenant) { @resource.command("snapshot", { "url" => @url }) }

      assert_equal MimeType::PAGE, answer["mime"]
      assert_equal @url, answer["url"]
      assert_equal "A page about pelicans", answer["title"]
      assert answer["digest"].present?
      assert_operator answer["height"].to_i, :>, 0
    end
  end

  test "get carries the text the page rendered, and list carries what was taken" do
    rendering do
      Tenant.switch(@tenant) do
        @resource.snapshot!(@url)

        got = @resource.command("get", { "url" => @url })
        assert_match(/Rather a lot about pelicans/, got["text"])

        listed = @resource.command("list", {})
        assert_equal [ @url ], listed["snapshots"].map { |entry| entry["url"] }
      end
    end
  end

  test "a private address is refused when fetching them is not allowed" do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")

    Tenant.switch(@tenant) do
      assert_raises(Snapshot::Blocked) { @resource.snapshot!(@url) }
    end
  end

  private

    def rendering
      skip "no browser to render with" unless Snapshot.available?

      yield
    end
end
