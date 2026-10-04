require "test_helper"

class FilesystemResourceTest < ActiveSupport::TestCase
  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "fs-#{SecureRandom.hex(4)}", name: "Files")

    @allowed = Pathname.new(Dir.mktmpdir("permitted"))
    @space = @allowed + @tenant.subdomain
    @root = @space + "catalog"
    @root.mkpath

    write "invoices/march.pdf", "contents of march"
    write "photos/beach.jpg", "contents of beach"
    write "notes.txt", "remember the milk"

    ENV["XIXO_FILESYSTEM_ROOTS"] = @allowed.to_s

    Tenant.switch(@tenant) do
      @resource = Resource::Filesystem.create!(
        key: "catalog-#{SecureRandom.hex(4)}",
        name: "Catalog",
        details: { "root" => @root.to_s }
      )
    end
  end

  teardown do
    ENV.delete("XIXO_FILESYSTEM_ROOTS")
    FileUtils.remove_entry(@allowed) if @allowed.exist?
  end

  test "syncing a tree catalogues every file, kind and title from the path" do
    sync

    Tenant.switch(@tenant) do
      assert_equal 3, Feed.files.count
      assert_equal "application/pdf", feed_at("invoices/march.pdf").mime
      assert_equal "march.pdf", feed_at("invoices/march.pdf").title
      assert_equal "image/jpeg", feed_at("photos/beach.jpg").mime
      assert_equal "text/plain", feed_at("notes.txt").mime
    end
  end

  test "the bytes stay on disk and come back through the reference" do
    sync

    Tenant.switch(@tenant) do
      assert_equal "remember the milk", feed_at("notes.txt").references.first.download.read
    end
  end

  test "syncing twice converges rather than accumulating" do
    2.times { sync }

    Tenant.switch(@tenant) { assert_equal 3, Feed.files.count }
  end

  test "the walk is deterministic, so a cursor resumes where it stopped" do
    seen = []
    @resource.each_page(cursor: "invoices/march.pdf") { |page, _| seen.concat(page.map(&:path)) }

    assert_equal [ "notes.txt", "photos/beach.jpg" ], seen
  end

  test "the cursor follows the walk, not string order" do
    write "a/deep.txt", "in a directory"
    write "a.txt", "beside it"

    walked = []
    @resource.each_page { |page, _| walked.concat(page.map(&:path)) }

    assert_operator walked.index("a/deep.txt"), :<, walked.index("a.txt")

    resumed = []
    @resource.each_page(cursor: "a/deep.txt") { |page, _| resumed.concat(page.map(&:path)) }

    assert_equal walked.drop(walked.index("a/deep.txt") + 1), resumed
  end

  test "one file looked up by its path is the file a sync would have made" do
    Tenant.switch(@tenant) do
      synced = nil
      @resource.each_page { |batch, _| synced ||= batch.find { |entry| entry.path == "invoices/march.pdf" } }

      assert_kept_as_synced(@resource, synced, @resource.object_for("invoices/march.pdf"))
      assert_kept_as_synced(@resource, synced, @resource.object_for("invoices/../invoices//march.pdf"))
    end
  end

  test "a kept file is found again by the next sync rather than catalogued twice" do
    kept = Tenant.switch(@tenant) { @resource.command(:keep, key: "notes.txt") }

    sync

    Tenant.switch(@tenant) do
      assert_equal 3, Feed.files.count
      assert_equal kept["id"], feed_at("notes.txt").id.to_s
    end
  end

  test "a file a sync would not walk is neither kept nor read, whether it climbs out, hides behind a symlink, or is a directory" do
    secret = @allowed + "secret.txt"
    secret.write("not yours")
    File.symlink(secret, @root + "escape.txt")
    File.symlink(@root + "invoices", @root + "linked")

    Tenant.switch(@tenant) do
      assert_raises(Resource::Filesystem::Escaped) { @resource.command(:keep, key: "../secret.txt") }
      assert_raises(Resource::Filesystem::Escaped) { @resource.command(:keep, key: "escape.txt") }
      assert_raises(Resource::Filesystem::Escaped) { @resource.command(:get, key: "../secret.txt") }
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "linked/march.pdf") }
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "invoices") }
      assert_raises(Resource::Failed) { @resource.command(:keep, key: "absent.txt") }

      @resource.update!(details: @resource.details.merge("prefix" => "photos"))

      assert_raises(ArgumentError) { @resource.command(:keep, key: "notes.txt") }
      assert_raises(ArgumentError) { @resource.command(:get, key: "notes.txt") }
      assert_raises(ArgumentError) { @resource.command(:list, prefix: "invoices") }
      assert_raises(ArgumentError) { @resource.command(:put, key: "notes.txt", body: "x") }
      assert_equal 0, Feed.files.count
    end
  end

  test "a root outside the permitted list is refused" do
    Tenant.switch(@tenant) do
      outside = Resource::Filesystem.create!(key: "outside", details: { "root" => Dir.mktmpdir("elsewhere") })

      assert_raises(Resource::Filesystem::Escaped) { outside.check! }
      assert_not outside.check
      assert_match(/outside every permitted/, outside.check_error)
    end
  end

  test "another tenant's directory under the same root is outside this one's" do
    other = Tenant.create!(subdomain: "fs-#{SecureRandom.hex(4)}", name: "Neighbour")
    theirs = (@allowed + other.subdomain + "private").tap(&:mkpath)
    (theirs + "ledger.txt").write("not yours")

    Tenant.switch(@tenant) do
      [ theirs.to_s, @allowed.to_s, "../#{other.subdomain}/private" ].each do |root|
        prying = Resource::Filesystem.create!(key: "pry-#{SecureRandom.hex(4)}", details: { "root" => root })

        assert_raises(Resource::Filesystem::Escaped, root) { prying.check! }
        assert_raises(Resource::Filesystem::Escaped, root) { prying.command(:list) }
        assert_raises(Resource::Filesystem::Escaped, root) { prying.command(:put, key: "x.txt", body: "x") }
      end
    end
  end

  test "a relative root is taken from the tenant's own directory, which is made on first use" do
    fresh = Tenant.create!(subdomain: "fs-#{SecureRandom.hex(4)}", name: "Fresh")

    Tenant.switch(fresh) do
      files = Resource::Filesystem.create!(key: "files", details: { "root" => "." })

      assert files.check!
      assert_equal (@allowed + fresh.subdomain).to_s, files.root.to_s
      files.upload("hello.txt", "hi")
    end

    assert_equal "hi", (@allowed + fresh.subdomain + "hello.txt").read
  end

  test "a root that is a symlink out of the tenant's directory is refused" do
    outside = Pathname.new(Dir.mktmpdir("outside"))
    File.symlink(outside, @space + "shortcut")

    Tenant.switch(@tenant) do
      linked = Resource::Filesystem.create!(key: "linked", details: { "root" => (@space + "shortcut").to_s })

      assert_raises(Resource::Filesystem::Escaped) { linked.check! }
    end
  ensure
    FileUtils.remove_entry(outside)
  end

  test "an upload onto a symlink writes nothing through it" do
    outside = @allowed + "outside.txt"
    outside.write("untouched")
    File.symlink(outside, @root + "link.txt")

    assert_raises(Resource::Filesystem::Escaped) { @resource.upload("link.txt", "overwritten") }

    assert_equal "untouched", outside.read
  end

  test "get reads a glimpse of a large file, not the whole of it, and says how big it is" do
    (@root + "huge.txt").open("wb") do |file|
      file.write("é" * Resource::GLIMPSE_BYTES)
      file.truncate(4.gigabytes)
    end

    got = @resource.command(:get, key: "huge.txt")

    assert_equal 4.gigabytes, got["size"]
    assert got["text"].start_with?("é" * 1000)
    assert_operator got["text"].length, :<=, Resource::MAX_TEXT
  end

  test "get still calls a file binary when its glimpse is" do
    (@root + "blob.bin").binwrite("\xFF\xFE\x00".b * 10)

    assert_nil @resource.command(:get, key: "blob.bin")["text"]
  end

  test "a walk that could not read a directory calls nothing gone, since what it missed may still be there" do
    sync
    write "locked/ledger.txt", "still here"
    locked = @root + "locked"
    unreadable = Module.new do
      define_method(:children) { |*args| basename.to_s == "locked" ? raise(Errno::EACCES, to_s) : super(*args) }
    end
    Pathname.prepend(unreadable)

    Tenant.switch(@tenant) do
      resource = Resource.find(@resource.id)
      walked = resource.walked_at
      walk = Resource::Walk.begin!(resource)
      resource.each_page(walk: walk) { |_, _| nil }

      assert walk.partial?
      assert_equal 0, walk.finish!(1.minute.from_now)
      assert_equal walked, resource.reload.walked_at, "a walk that missed something is not a full one"
    end
  ensure
    unreadable&.send(:define_method, :children) { |*args| super(*args) }
    FileUtils.remove_entry(locked) if locked&.exist?
  end

  test "no permitted roots at all means the type is unusable" do
    ENV.delete("XIXO_FILESYSTEM_ROOTS")

    error = assert_raises(Resource::Failed) { @resource.check! }
    assert_match(/XIXO_FILESYSTEM_ROOTS/, error.message)
  end

  test "a locator climbing out of the root is refused" do
    write "secret.txt", "not yours", from: @allowed

    error = assert_raises(Resource::Filesystem::Escaped) { @resource.download("path" => "../secret.txt") }
    assert_match(/resolves outside/, error.message)
  end

  test "climbing out is an escape whether or not anything is there" do
    write "secret.txt", "not yours", from: @allowed

    present = assert_raises(Resource::Filesystem::Escaped) { @resource.download("path" => "../secret.txt") }
    absent = assert_raises(Resource::Filesystem::Escaped) { @resource.download("path" => "../nothing.txt") }

    assert_equal present.message.sub("secret", "nothing"), absent.message
  end

  test "a symlink pointing out of the root is neither walked nor followed" do
    secret = @allowed + "secret.txt"
    secret.write("not yours")
    File.symlink(secret, @root + "escape.txt")

    sync

    Tenant.switch(@tenant) { assert_equal 3, Feed.files.count }
    assert_raises(Resource::Filesystem::Escaped) { @resource.download("path" => "escape.txt") }
  end

  test "an upload climbing out of the root is refused before anything is written" do
    assert_raises(Resource::Filesystem::Escaped) { @resource.upload("../escaped.txt", "nope") }

    assert_not (@allowed + "escaped.txt").exist?
  end

  test "it is storage, so export writes into it and records the reference" do
    Tenant.switch(@tenant) do
      destination = Resource::Filesystem.create!(key: "backup", details: { "root" => backup_root.to_s })
      sync
      Tenant.switch(@tenant) { ExportItemsJob.perform_now(@tenant.id, destination.id, {}) }

      assert_equal "remember the milk", (backup_root + @resource.key + "notes.txt").read
      assert_equal 2, feed_at("notes.txt").references.count
    end
  end

  private

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end

    def backup_root
      @backup_root ||= (@space + "backup").tap(&:mkpath)
    end

    def write(path, contents, from: @root)
      target = from + path
      target.dirname.mkpath
      target.write(contents)
    end

    def feed_at(locator_key)
      Feed.joins(:references).find_by!(feed_references: { locator_key: locator_key })
    end
end
