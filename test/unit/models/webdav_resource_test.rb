require "test_helper"
require_relative "../../support/fake_dav_server"

class WebdavResourceTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    ENV["URIS_ALLOW_PRIVATE_FETCH"] = "1"

    @server = FakeDavServer.current
    @server.reset!
    @server.put "invoices/march.pdf", "contents of march"
    @server.put "photos/beach.jpg", "contents of beach"
    @server.put "notes.txt", "remember the milk"

    @tenant = Tenant.create!(subdomain: "dav-#{SecureRandom.hex(4)}", name: "Dav")

    Tenant.switch(@tenant) do
      @resource = Resource::Webdav.create!(
        key: "dav-#{SecureRandom.hex(4)}",
        name: "Files",
        details: { "url" => @server.url },
        credentials: { "username" => "someone", "password" => "irrelevant" }
      )
    end
  end

  teardown do
    ENV.delete("URIS_ALLOW_PRIVATE_FETCH")
  end

  test "syncing walks collections and catalogues every file" do
    sync

    Tenant.switch(@tenant) do
      assert_equal 3, Feed.files.count
      assert_equal "application/pdf", feed_at("invoices/march.pdf").mime
      assert_equal "march.pdf", feed_at("invoices/march.pdf").title
      assert_equal "image/jpeg", feed_at("photos/beach.jpg").mime
      assert_equal "text/plain", feed_at("notes.txt").mime
    end
  end

  test "the locator carries the etag, so a change has a signal to hang on" do
    sync

    Tenant.switch(@tenant) do
      assert feed_at("notes.txt").references.first.locator["etag"].present?
    end
  end

  test "the bytes come back through the reference" do
    sync

    Tenant.switch(@tenant) do
      assert_equal "remember the milk", feed_at("notes.txt").references.first.download.read
    end
  end

  test "syncing twice converges rather than accumulating" do
    2.times { sync }

    Tenant.switch(@tenant) { assert_equal 3, Feed.files.count }
  end

  test "one file looked up by its path is the file a sync would have made" do
    synced = nil
    @resource.each_page { |batch, _| synced ||= batch.find { |entry| entry.path == "invoices/march.pdf" } }

    assert_kept_as_synced(@resource, synced, @resource.object_for("invoices/march.pdf"))
  end

  test "a kept file is found again by the next sync rather than catalogued twice" do
    kept = Tenant.switch(@tenant) { @resource.command(:keep, key: "invoices/march.pdf") }

    Tenant.switch(@tenant) { assert_equal "application/pdf", kept["mime"] }

    sync

    Tenant.switch(@tenant) do
      assert_equal 3, Feed.files.count
      assert_equal kept["id"], feed_at("invoices/march.pdf").id.to_s
    end
  end

  test "a collection, a missing file, or one outside the prefix is neither kept nor read" do
    Tenant.switch(@tenant) do
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "invoices") }
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "absent.txt") }
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "../elsewhere.txt") }

      @resource.update!(details: @resource.details.merge("prefix" => "photos"))

      assert_raises(ArgumentError) { @resource.command(:keep, key: "notes.txt") }
      assert_raises(ArgumentError) { @resource.command(:get, key: "notes.txt") }
      assert_raises(ArgumentError) { @resource.command(:list, prefix: "invoices") }
      assert_raises(ArgumentError) { @resource.command(:put, key: "notes.txt", body: "x") }
      assert_equal 0, Feed.files.count
    end
  end

  test "a cursor resumes where the walk stopped" do
    seen = []
    @resource.each_page(cursor: "invoices/march.pdf") { |page, _| seen.concat(page.map(&:path)) }

    assert_equal [ "notes.txt", "photos/beach.jpg" ], seen
  end

  test "it is storage, and uploading creates the collections it needs" do
    @resource.upload("backup/deep/notes.txt", "written by items")

    assert_equal "written by items", @server.read("backup/deep/notes.txt")
  end

  test "export writes into it and records the second reference" do
    Tenant.switch(@tenant) do
      destination = Resource::Webdav.create!(
        key: "backup-#{SecureRandom.hex(4)}",
        details: { "url" => @server.url, "prefix" => "backup" },
        credentials: { "username" => "someone", "password" => "irrelevant" }
      )
      sync
      Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, destination.id, { "kind" => "text" }) }

      assert_equal "remember the milk", @server.read("#{@resource.key}/notes.txt")
      assert_equal 2, feed_at("notes.txt").references.count
    end
  end

  test "a resource whose credentials went missing fails rather than reading anonymously" do
    Tenant.switch(@tenant) do
      @resource.update!(credentials: {})

      assert_raises(Resource::Failed) { @resource.check! }
    end
  end

  test "a private address is refused unless fetching them is allowed" do
    ENV.delete("URIS_ALLOW_PRIVATE_FETCH")

    assert_raises(PublicFetch::Blocked) { @resource.check! }
  end

  test "a key cannot climb out of the collection to another on the same server" do
    Tenant.switch(@tenant) do
      [ "../other/secret.txt", "photos/../../other/secret.txt", "./notes.txt" ].each do |key|
        error = assert_raises(Resource::Failed) { @resource.command(:get, key: key) }

        assert_match(/climbs out/, error.message)
      end
    end
  end

  test "a redirect to another origin goes without the credentials, and one within the server keeps them" do
    ENV.delete("URIS_ALLOW_PRIVATE_FETCH")
    carried = {}

    stub_request(:get, "https://dav.example.test/files/moved.txt")
      .to_return(status: 302, headers: { "Location" => "https://elsewhere.example.test/taken" })
    stub_request(:get, "https://elsewhere.example.test/taken").to_return do |request|
      carried[:elsewhere] = request.headers.transform_keys(&:downcase)
      { status: 200, body: "taken" }
    end
    stub_request(:get, "https://dav.example.test/files/renamed.txt")
      .to_return(status: 301, headers: { "Location" => "/files/notes.txt" })
    stub_request(:get, "https://dav.example.test/files/notes.txt").to_return do |request|
      carried[:home] = request.headers.transform_keys(&:downcase)
      { status: 200, body: "remember the milk" }
    end

    Tenant.switch(@tenant) do
      @resource.update!(details: { "url" => "https://dav.example.test/files/" })

      @resource.download("path" => "moved.txt").read
      @resource.download("path" => "renamed.txt").read
    end

    assert_not carried[:elsewhere].key?("authorization"), "the password does not follow a redirect off the server"
    assert carried[:home].key?("authorization")
  end

  private

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end

    def feed_at(locator_key)
      Feed.joins(:references).find_by!(feed_references: { locator_key: locator_key })
    end
end
