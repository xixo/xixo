require "test_helper"

class UploadsTest < ActionDispatch::IntegrationTest
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "up-#{SecureRandom.hex(4)}", name: "Uploads")
    @other = Tenant.create!(subdomain: "up-#{SecureRandom.hex(4)}", name: "Elsewhere")

    @allowed = Pathname.new(Dir.mktmpdir("permitted"))
    @root = @allowed + @tenant.subdomain + "drop"
    @root.mkpath

    ENV["XIXO_FILESYSTEM_ROOTS"] = @allowed.to_s

    Tenant.switch(@tenant) do
      @storage = Resource::Filesystem.create!(
        key: "drop-#{SecureRandom.hex(4)}", name: "Drop", details: { "root" => @root.to_s }
      )
      @storage.make_default_storage!
    end

    connect!(@tenant)
    connect!(@other)
  end

  teardown do
    ENV.delete("XIXO_FILESYSTEM_ROOTS")
    FileUtils.remove_entry(@allowed) if @allowed.exist?
  end

  test "a dropped file is staged and answered at once, before it is stored anywhere" do
    assert_enqueued_jobs 1, only: AnalyzeFeedJob do
      upload "march.txt", "contents of march"
    end

    assert_response :accepted

    body = response.parsed_body

    assert_equal "text/plain", body["mime"]
    assert_equal "march.txt", body["path"]
    assert_not (@root + "march.txt").exist?

    Tenant.switch(@tenant) do
      feed = Feed.find(body["feed_id"])
      analysis = Analysis.find(body["analysis_id"])

      assert feed.staged?
      assert_empty feed.references
      assert_equal "upload", analysis.cause
      assert_equal feed.id, analysis.feed_id
    end
  end

  test "the pass stores a staged file in default storage, records why, and lets the staged copy go" do
    upload "march.txt", "contents of march"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "contents of march", (@root + "march.txt").read

    Tenant.switch(@tenant) do
      feed = feed_at("march.txt")
      placed = Analysis.find(response.parsed_body["analysis_id"]).step_result("placement")

      assert_equal @storage.id, feed.resource.id
      assert_equal "text/plain", feed.mime
      assert_not feed.staged?
      assert_equal 0, ActiveStorage::Blob.count
      assert_equal({ "resource" => @storage.key, "path" => "march.txt", "by" => "default",
                     "reason" => "default storage" }, placed)
      assert_not_nil feed.analyzed_at
    end
  end

  test "a dropped folder keeps its shape as the locator key" do
    upload "beach.txt", "sand", path: "photos/2024/beach.txt"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "photos/2024/beach.txt", response.parsed_body["path"]
    assert_equal "sand", (@root + "photos/2024/beach.txt").read
  end

  test "a path that climbs out of the resource is flattened, not followed" do
    upload "escape.txt", "nope", path: "../../etc/escape.txt"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "etc/escape.txt", response.parsed_body["path"]
    assert_equal "nope", (@root + "etc/escape.txt").read
    assert_not (@allowed.parent + "etc/escape.txt").exist?
  end

  test "a path with nothing usable left in it is refused" do
    upload "..", "nope", path: "../.."

    assert_response :unprocessable_content
    assert_match(/not a usable path/, response.parsed_body["error"])
  end

  test "dropping the same path twice before the pass runs stages one feed, holding the second" do
    upload "notes.txt", "first"
    upload "notes.txt", "second"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "second", (@root + "notes.txt").read

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal 1, Reference.where(locator_key: "notes.txt").count
    end
  end

  test "dropping a path again once it is stored replaces the file and marks it changed" do
    upload "notes.txt", "first"
    perform_enqueued_jobs(only: AnalyzeFeedJob)
    upload "notes.txt", "second"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "second", (@root + "notes.txt").read

    Tenant.switch(@tenant) do
      reference = Reference.find_by!(locator_key: "notes.txt")

      assert_equal 1, Feed.files.count
      assert_not_nil reference.changed_at
      assert_equal "return", Analysis.newest_first.first.step_result("placement")["by"]
    end
  end

  test "the same bytes dropped under another name are answered as already there, not stored twice" do
    first = upload("march.txt", "the same bytes") && response.parsed_body
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_no_enqueued_jobs only: AnalyzeFeedJob do
      upload "march-copy.txt", "the same bytes"
    end

    assert_response :ok

    body = response.parsed_body

    assert_equal true, body["duplicate"]
    assert_equal first["feed_id"], body["feed_id"]
    assert_equal "march.txt", body["twin"].split("/").last
    assert_not (@root + "march-copy.txt").exist?

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal 1, Reference.originals.count
    end
  end

  test "the same bytes dropped while the first is still waiting to be stored are one item too" do
    first = upload("march.txt", "still waiting") && response.parsed_body
    upload "elsewhere/march.txt", "still waiting"

    assert_response :ok
    assert_equal true, response.parsed_body["duplicate"]
    assert_equal first["feed_id"], response.parsed_body["feed_id"]

    Tenant.switch(@tenant) { assert_equal 1, Feed.files.count }
  end

  test "the fingerprint of what was stored is kept on the reference" do
    upload "march.txt", "fingerprinted"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      assert_equal Digest::SHA256.hexdigest("fingerprinted"), Reference.find_by!(locator_key: "march.txt").digest
    end
  end

  test "changed bytes at a known path are not a duplicate of the old ones" do
    upload "march.txt", "before"
    perform_enqueued_jobs(only: AnalyzeFeedJob)
    upload "march.txt", "after"

    assert_response :accepted
    assert_nil response.parsed_body["duplicate"]
  end

  test "a file another tenant holds is not a duplicate here" do
    Tenant.switch(@other) do
      feed = Feed.create!(type: Feed::FILE, key: "theirs.txt", title: "theirs.txt")
      resource = Resource::Database.create!(key: "theirs-#{SecureRandom.hex(3)}", name: "Theirs")

      Reference.create!(feed: feed, resource: resource, locator_key: "theirs.txt", role: Reference::ORIGINAL,
                        digest: Digest::SHA256.hexdigest("private to them"))
    end

    upload "mine.txt", "private to them"

    assert_response :accepted
    assert_nil response.parsed_body["duplicate"]
  end

  test "a file on someone else's personal resource is not revealed as a duplicate" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "theirs.txt", title: "theirs.txt")
      private_store = Resource::Database.create!(key: "private-#{SecureRandom.hex(3)}", name: "Private",
                                                 owner_subject: "someone-else")

      Reference.create!(feed: feed, resource: private_store, locator_key: "theirs.txt", role: Reference::ORIGINAL,
                        digest: Digest::SHA256.hexdigest("their secret"))
    end

    upload "probe.txt", "their secret"

    assert_response :accepted
    assert_nil response.parsed_body["duplicate"]
  end

  test "a file on the uploader's own personal resource is not a twin of a shared upload" do
    Tenant.switch(@tenant) do
      own = @allowed + @tenant.subdomain + "own"
      own.mkpath
      feed = Feed.create!(type: Feed::FILE, key: "mine.txt", title: "mine.txt")
      personal = Resource::Filesystem.create!(key: "own-#{SecureRandom.hex(3)}", name: "Own",
                                              details: { "root" => own.to_s }, owner_subject: "test")

      Reference.create!(feed: feed, resource: personal, locator_key: "mine.txt", role: Reference::ORIGINAL,
                        digest: Digest::SHA256.hexdigest("my own bytes"))
    end

    upload "shared.txt", "my own bytes"

    assert_response :accepted
    assert_nil response.parsed_body["duplicate"]
  end

  test "a file on an archived resource is not a duplicate" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::FILE, key: "old.txt", title: "old.txt")
      old = Resource::Database.create!(key: "old-#{SecureRandom.hex(3)}", name: "Old")

      Reference.create!(feed: feed, resource: old, locator_key: "old.txt", role: Reference::ORIGINAL,
                        digest: Digest::SHA256.hexdigest("archived bytes"))
      old.update_columns(archived_at: Time.current)
    end

    upload "again.txt", "archived bytes"

    assert_response :accepted
    assert_nil response.parsed_body["duplicate"]
  end

  test "a tenant with nowhere that accepts the file is told so rather than staging it" do
    Tenant.switch(@tenant) { @storage.update!(archived_at: Time.current) }

    upload "march.pdf", "contents"

    assert_response :unprocessable_content
    assert_match(/nowhere accepts/, response.parsed_body["error"])
    Tenant.switch(@tenant) do
      assert_equal 0, Feed.files.count
      assert_equal 0, ActiveStorage::Blob.count
    end
  end

  test "a tenant with storage but no default still stores the file somewhere that accepts it" do
    Tenant.switch(@tenant) { @storage.update!(default_storage: false) }

    upload "march.txt", "contents"
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    assert_equal "contents", (@root + "march.txt").read
  end

  test "a token that may read but not write cannot drop anything" do
    upload "march.pdf", "contents", scopes: [ "xixo:catalog:read" ]

    assert_response :unauthorized
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  test "a token minted for another tenant cannot drop into this one" do
    post "/uploads",
         params: { file: uploaded("march.pdf", "contents") },
         headers: host_for(@tenant).merge(bearer(@other))

    assert_response :unauthorized
    Tenant.switch(@tenant) { assert_equal 0, Feed.files.count }
  end

  private

    def upload(name, contents, path: nil, scopes: Grant::SCOPES)
      post "/uploads",
           params: { file: uploaded(name, contents), path: path }.compact,
           headers: host_for(@tenant).merge(bearer(@tenant, scopes: scopes))
    end

    def uploaded(name, contents)
      file = Tempfile.new([ "drop", File.extname(name) ])
      file.binmode
      file.write(contents)
      file.rewind

      Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: name)
    end

    def host_for(tenant)
      { "HOST" => "#{tenant.subdomain}.xixo.test" }
    end

    def bearer(tenant, scopes: Grant::SCOPES)
      token = issuer.mint(
        subdomain: tenant.subdomain, scopes: scopes,
        audience: "http://#{tenant.subdomain}.xixo.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end
end
