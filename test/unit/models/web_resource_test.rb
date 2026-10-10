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

  test "a watchlist makes it syncable, and lets it keep a schedule" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "watchlist" => [ @url ] })

      assert @resource.syncable?

      @resource.update!(sync_interval: 300)

      assert_equal 300, @resource.reload.sync_interval
    end
  end

  test "an empty watchlist is no watchlist" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "watchlist" => [ " ", "" ] })

      refute @resource.syncable?
      refute @resource.details.key?("watchlist")
    end
  end

  test "the watchlist is set one address per line, and kept canonical and once each" do
    details, = Resource::Settings.for(Resource::Web, { "watchlist" => "#{@url}\n\n  #{@url}#top\nhttps://example.com" })

    Tenant.switch(@tenant) do
      @resource.update!(details: details)

      assert_equal [ @url, "https://example.com/" ], @resource.details["watchlist"]
    end
  end

  test "a watched address is an http address on a public host" do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")

    Tenant.switch(@tenant) do
      {
        "ftp://example.com/" => /not an http or https address/,
        "file:///etc/passwd" => /not an http or https address/,
        "https://ada:secret@example.com/" => /username or password/,
        "http://127.0.0.1/admin" => /not a public address/,
        "http://[::1]/" => /not a public address/,
        "http://169.254.169.254/latest/meta-data" => /not a public address/,
        "https://example.com/#{'a' * Resource::Web::LONGEST}" => /longer than/
      }.each do |url, refusal|
        @resource.details = { "watchlist" => [ url ] }

        refute @resource.valid?, "#{url} should be refused"
        assert_match refusal, @resource.errors.full_messages.to_sentence
      end
    end
  end

  test "a watchlist holds a bounded number of addresses" do
    Tenant.switch(@tenant) do
      @resource.details = { "watchlist" => (0..Resource::Web::WATCHING).map { |n| "https://example.com/#{n}" } }

      refute @resource.valid?
      assert_match(/at most #{Resource::Web::WATCHING}/, @resource.errors.full_messages.to_sentence)
    end
  end

  test "each page is one watched address, and a sync resumes after the last one taken" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "watchlist" => %w[https://example.com/a https://example.com/b https://example.com/c] })

      pages = []
      @resource.each_page { |page, cursor| pages << [ page, cursor ] }

      assert_equal [ [ [ "https://example.com/a" ], "https://example.com/a" ],
                     [ [ "https://example.com/b" ], "https://example.com/b" ],
                     [ [ "https://example.com/c" ], "https://example.com/c" ] ], pages

      resumed = []
      @resource.each_page(cursor: "https://example.com/a") { |page, _| resumed.concat(page) }

      assert_equal %w[https://example.com/b https://example.com/c], resumed

      restarted = []
      @resource.each_page(cursor: "https://example.com/gone") { |page, _| restarted.concat(page) }

      assert_equal 3, restarted.size
    end
  end

  test "a sync snapshots every watched address and notices a change" do
    rendering do
      other = @server.serve_body("/other.html", CHANGED, content_type: "text/html")
      Tenant.switch(@tenant) { @resource.update!(details: { "watchlist" => [ @url, other ] }) }

      sync

      was = Tenant.switch(@tenant) do
        assert_equal [ @url, other ].sort, Reference.where(resource_id: @resource.id).pluck(:locator_key).sort
        assert Reference.where(resource_id: @resource.id).all?(&:seen_at)

        Reference.find_by!(locator_key: @url).version
      end
      @server.serve_body("/page.html", CHANGED, content_type: "text/html")

      sync

      Tenant.switch(@tenant) do
        assert_equal 2, Feed.files.count
        refute_equal was, Reference.find_by!(locator_key: @url).version
      end
    end
  end

  test "an address taken off the watchlist is gone after the next sync" do
    rendering do
      other = @server.serve_body("/other.html", CHANGED, content_type: "text/html")
      Tenant.switch(@tenant) { @resource.update!(details: { "watchlist" => [ @url, other ] }) }

      sync

      Tenant.switch(@tenant) { @resource.command("unwatch", { "url" => other }) }

      sync

      Tenant.switch(@tenant) do
        assert_nil Reference.find_by!(locator_key: @url).gone_at
        assert Reference.find_by!(locator_key: other).gone_at.present?
      end
    end
  end

  test "an address that fails is skipped, logged, and not taken for gone" do
    rendering do
      broken = @server.serve_body("/broken.html", CHANGED, content_type: "text/html")
      Tenant.switch(@tenant) { @resource.update!(details: { "watchlist" => [ broken, @url ] }) }

      sync
      again = Time.current
      failing(broken) { sync(logged: true) }

      Tenant.switch(@tenant) do
        assert_nil Reference.find_by!(locator_key: broken).gone_at
        assert_operator Reference.find_by!(locator_key: broken).seen_at, :>=, again
        assert_operator Reference.find_by!(locator_key: @url).seen_at, :>=, again

        run = Run.where(resource: @resource).order(:id).last
        assert_equal "done", run.status
        assert_match(/broken\.html.*would not render/, run.logs)
      end
    end
  end

  test "a sync with no browser stops, since no address could be taken" do
    Tenant.switch(@tenant) { @resource.update!(details: { "watchlist" => [ @url ] }) }

    error = assert_raises(Resource::Unusable) do
      unavailable { Tenant.switch(@tenant) { @resource.keep!(@url) } }
    end

    assert_match(/no browser/, error.message)
  end

  test "watch puts an address on the watchlist, and unwatch takes it off along with the schedule" do
    Tenant.switch(@tenant) do
      answer = @resource.command("watch", { "url" => "#{@url}#here" })

      assert_equal [ @url ], answer["watching"]
      assert @resource.reload.syncable?

      @resource.update!(sync_interval: 300)
      @resource.command("unwatch", { "url" => @url })

      refute @resource.reload.syncable?
      assert_nil @resource.sync_interval
      assert_raises(Resource::Web::Gone) { @resource.command("unwatch", { "url" => @url }) }
    end
  end

  test "watch refuses an address it would never take" do
    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Refused) { @resource.command("watch", { "url" => "file:///etc/passwd" }) }

      assert_match(/not an http or https address/, error.message)
      refute @resource.reload.syncable?
    end
  end

  test "list says what is being watched" do
    Tenant.switch(@tenant) do
      @resource.command("watch", { "url" => @url })

      assert_equal [ @url ], @resource.command("list", {})["watching"]
    end
  end

  private

    def sync(logged: false)
      run = logged ? Tenant.switch(@tenant) { Run.start!(kind: "sync", resource: @resource) } : nil

      Tenant.switch(@tenant) do
        Resource.find(@resource.id).claim_sync!
        SyncResourceJob.perform_now(@tenant.id, @resource.id, run&.id)
      end
    end

    def failing(url)
      Snapshot.singleton_class.alias_method(:unfailing_of, :of)
      Snapshot.define_singleton_method(:of) do |wanted, **options|
        raise Snapshot::Failed, "#{wanted} would not render" if wanted == url

        unfailing_of(wanted, **options)
      end

      yield
    ensure
      Snapshot.singleton_class.alias_method(:of, :unfailing_of)
    end

    def unavailable
      Snapshot.singleton_class.alias_method(:available_of, :of)
      Snapshot.define_singleton_method(:of) { |*, **| raise Snapshot::Unavailable, "no browser to render with" }

      yield
    ensure
      Snapshot.singleton_class.alias_method(:of, :available_of)
    end

    def rendering
      skip "no browser to render with" unless Snapshot.available?

      yield
    end
end
