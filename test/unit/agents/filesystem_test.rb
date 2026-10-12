require "test_helper"
require_relative "../../support/machines"

class FilesystemTest < ActiveSupport::TestCase
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "folders-#{SecureRandom.hex(4)}", name: "Folders")
    @agent = agent_on(@tenant, folders: [ "/srv/media", "/srv/photos" ])
  end

  test "a folder is attached only through an agent, and only one the agent shares" do
    Tenant.switch(@tenant) do
      held = Resource::Filesystem.new(key: "media", details: { "folder" => "/srv/media" }, via: @agent)
      assert held.valid?, held.errors.full_messages.to_sentence

      elsewhere = Resource::Filesystem.new(key: "etc", details: { "folder" => "/etc" }, via: @agent)
      assert_not elsewhere.valid?
      assert_match(%r{/etc is not one the agent on box shares. It shares /srv/media and /srv/photos}, elsewhere.errors.full_messages.to_sentence)

      direct = Resource::Filesystem.new(key: "direct", details: { "folder" => "/srv/media" })
      assert_not direct.valid?

      tailnet = Resource::Tailnet.create!(key: "tailnet")
      through_tailnet = Resource::Filesystem.new(key: "far", details: { "folder" => "/srv/media" }, via: tailnet)
      assert_not through_tailnet.valid?
    end
  end

  test "a folder on a machine is held for one owner, and a folder inside or around it for the same one" do
    Tenant.switch(@tenant) do
      @agent.update!(details: @agent.details.merge("machine" => @agent.machine.merge(
        "folders" => [ "/", "/srv", "/srv/media", "/srv/media/films", "/srv/photos", "/srv/photos/2026" ]
      )))
      Resource::Filesystem.create!(key: "shared", details: { "folder" => "/srv/media" }, via: @agent)

      [ "/srv/media", "/srv/media/films", "/srv", "/" ].each do |path|
        mine = Resource::Filesystem.new(key: "mine", details: { "folder" => path }, via: @agent, owner_subject: "alice")
        assert_not mine.valid?, path
        assert_match(/overlaps \/srv\/media, which another folder on box holds for everyone/, mine.errors.full_messages.to_sentence)
      end

      beside = Resource::Filesystem.new(key: "photos", details: { "folder" => "/srv/photos" }, via: @agent, owner_subject: "alice")
      assert beside.valid?, beside.errors.full_messages.to_sentence
      beside.save!

      inside = Resource::Filesystem.new(key: "films", details: { "folder" => "/srv/media/films" }, via: @agent)
      assert inside.valid?, inside.errors.full_messages.to_sentence

      bobs = Resource::Filesystem.new(key: "bobs", details: { "folder" => "/srv/photos/2026" }, via: @agent, owner_subject: "bob")
      assert_not bobs.valid?
      assert_match(/holds for one person/, bobs.errors.full_messages.to_sentence)

      elsewhere = agent_on(@tenant, key: "other", folders: [ "/srv/media" ])
      apart = Resource::Filesystem.new(key: "apart", details: { "folder" => "/srv/media" }, via: elsewhere, owner_subject: "bob")
      assert apart.valid?, apart.errors.full_messages.to_sentence
    end
  end

  test "a member cannot reach a folder through a machine, by attaching or by changing" do
    Tenant.switch(@tenant) do
      member = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "alice", "scope" => Grant::SIGN_IN.join(" ")))

      refused = assert_raises(Resource::Refused) do
        Resource::Attaching.new("filesystem", grant: member).attach!(key: "mine", settings: { "folder" => "/srv/photos" },
                                                                     via: "box", personal: true)
      end
      assert_match(/only an administrator reaches a folder through a machine/, refused.message)

      held = Resource::Filesystem.create!(key: "held", details: { "folder" => "/srv/photos" }, via: @agent, owner_subject: "alice")
      assert_raises(Resource::Refused) { Resource::Changing.new(held, grant: member).change!(settings: { "folder" => "/srv/media" }) }
      assert_equal "/srv/photos", held.reload.folder
    end
  end

  test "an agent reaches nothing but its folders" do
    Tenant.switch(@tenant) do
      dav = Resource::Webdav.new(key: "dav", details: { "url" => "http://100.64.0.9/dav/" }, via: @agent)

      assert_not dav.valid?
      assert_match(/box reaches nothing of this kind/, dav.errors.full_messages.to_sentence)
    end
  end

  test "a sync walks the folder through the agent page by page" do
    Tenant.switch(@tenant) do
      folder = attached
      asked = answering(folder, [
        { "entries" => [ entry("a.txt"), entry("b/c.txt") ], "cursor" => "b/c.txt" },
        { "entries" => [ entry("d.txt") ] }
      ])

      pages = []
      folder.each_page { |page, cursor| pages << [ page.map(&:path), cursor ] }

      assert_equal [ [ %w[a.txt b/c.txt], "b/c.txt" ], [ %w[d.txt], "d.txt" ] ], pages
      assert_equal [ nil, "b/c.txt" ], asked.map { |args| args["cursor"] }
      assert_equal [ "/srv/media" ], asked.map { |args| args["folder"] }.uniq
      first = folder.locator_for(Resource::Filesystem::Entry.new(path: "a", size: 5, modified_at: Time.utc(2026, 10, 11, 12)))
      assert_equal "2026-10-11T12:00:00Z:5", folder.version_for(first)
    end
  end

  test "a path the agent lists that climbs out of the folder fails the sync" do
    Tenant.switch(@tenant) do
      [ "../etc/passwd", "/etc/passwd", "a/../../b", "a//b", "" ].each do |path|
        folder = attached
        answering(folder, [ { "entries" => [ entry(path) ] } ])

        assert_raises(Resource::Failed, path) { folder.each_page { |*| nil } }
      end
    end
  end

  test "a download names only paths inside the folder" do
    Tenant.switch(@tenant) do
      folder = attached
      read = []
      folder.agent.define_singleton_method(:read) { |shared, path| read << [ shared, path ] && StringIO.new("x") }

      assert_equal "x", folder.download({ "path" => "b/c.txt" }).read
      assert_raises(Resource::Failed) { folder.download({ "path" => "../../etc/shadow" }) }
      assert_equal [ [ "/srv/media", "b/c.txt" ] ], read
    end
  end

  test "a glimpse asks the agent for only the bytes it shows, and says the file's whole size" do
    Tenant.switch(@tenant) do
      folder = attached
      answering(folder, [ { "entries" => [ entry("big.log") ] } ])
      glimpsed = []
      folder.agent.define_singleton_method(:read) { |*| raise "a glimpse read the whole file" }
      folder.agent.define_singleton_method(:glimpse) do |shared, path, limit:|
        glimpsed << [ shared, path, limit ]
        [ "the first lines", 5_000_000_000 ]
      end

      held = folder.command_get(key: "big.log")

      assert_equal [ [ "/srv/media", "big.log", Resource::GLIMPSE_BYTES ] ], glimpsed
      assert_equal 5_000_000_000, held["size"]
      assert_equal "the first lines", held["text"]
    end
  end

  test "a folder the agent stopped sharing is not asked for" do
    Tenant.switch(@tenant) do
      folder = attached
      folder.agent.details = folder.agent.details.merge("machine" => folder.agent.machine.merge("folders" => [ "/srv/photos" ]))
      asked = answering(folder, [])

      error = assert_raises(Resource::Unusable) { folder.each_page { |*| nil } }
      assert_match(%r{no longer shares /srv/media}, error.message)
      assert_match(%r{no longer shares /srv/media}, Resource.find(folder.id).check_error)
      assert_raises(Resource::Unusable) { folder.download({ "path" => "a.txt" }) }
      assert_empty asked
    end
  end

  test "the agent offers its folders to attach" do
    Tenant.switch(@tenant) do
      offered = @agent.discovered(services: true)

      assert_equal %w[media photos], offered.map { |node| node["host_name"] }
      assert_equal [ "/srv/media" ], offered.first["services"].map { |service| service["address"] }
      assert_equal [ "filesystem" ], offered.first["services"].map { |service| service["type"] }
    end
  end

  test "an upload is written through the agent into a writable folder, and the catalog's own file is replaced" do
    root = Pathname.new(Dir.mktmpdir("writable"))

    Tenant.switch(@tenant) do
      folder = disk_folder(root, key: "files", default_storage: true)

      locator = folder.upload("drop/march.txt", StringIO.new("contents of march"))
      assert_equal "contents of march", (root + "drop/march.txt").read
      assert_equal "drop/march.txt", locator["path"]
      assert_equal 17, locator["size"]
      assert folder.version_for(locator).present?

      error = assert_raises(Resource::Failed) { folder.upload("drop/march.txt", StringIO.new("again")) }
      assert_match(/a file is already at that path/, error.message)

      Reference.create!(feed: Feed.create!(type: Feed::FILE, key: "march"), resource: folder,
                        locator_key: "drop/march.txt", locator: locator)
      folder.upload("drop/march.txt", StringIO.new("replaced"))
      assert_equal "replaced", (root + "drop/march.txt").read
      assert_empty FakeDisk.staged
    end
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  test "a read-only folder takes no upload, accepts nothing, and cannot be default storage" do
    root = Pathname.new(Dir.mktmpdir("kept"))

    Tenant.switch(@tenant) do
      folder = disk_folder(root, key: "kept", writable: false)

      assert_not folder.writable?
      assert_empty folder.serving["accepts"]
      assert_not Resource.placeable("text/plain").exists?(folder.id)
      assert_raises(Resource::Refused) { folder.upload("note.txt", StringIO.new("x")) }
      assert_empty root.children

      writable = disk_folder(Pathname.new(Dir.mktmpdir("open")), key: "open")
      assert writable.writable?
      assert_equal [ "*/*" ], writable.serving["accepts"]
      assert Resource.placeable("text/plain").exists?(writable.id)
    end
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  test "a folder's storage follows what the agent says about writing when it says hello" do
    Tenant.switch(@tenant) do
      folder = attached
      assert_empty folder.serving["accepts"]

      @agent.greeted!({ "folders" => [ "/srv/media" ], "writable" => [ "/srv/media" ] }, session: "s2")
      assert_equal [ "*/*" ], folder.reload.serving["accepts"]

      @agent.greeted!({ "folders" => [ "/srv/media" ], "writable" => [] }, session: "s3")
      assert_empty folder.reload.serving["accepts"]
    end
  end

  test "a folder is accepted before its agent has said which folders it shares" do
    Tenant.switch(@tenant) do
      quiet = Resource::XixoAgent.create!(key: "quiet", name: "Quiet", details: { "local" => true })
      folder = Resource::Filesystem.new(key: "files", details: { "folder" => "/data/files/x" }, via: quiet)

      assert folder.valid?, folder.errors.full_messages.to_sentence
      assert_equal [ "*/*" ], folder.served["accepts"]
      assert_not Resource::Filesystem.new(key: "rel", details: { "folder" => "files" }, via: quiet).valid?
    end
  end

  private

    def attached
      Resource::Filesystem.create!(key: "media-#{SecureRandom.hex(2)}", details: { "folder" => "/srv/media" }, via: @agent)
    end

    def entry(path)
      { "path" => path, "size" => 5, "modified_at" => "2026-10-11T12:00:00Z" }
    end

    def answering(folder, pages)
      asked = []
      folder.agent.define_singleton_method(:ask) do |verb, args = {}, **|
        raise "asked #{verb}" unless verb == "list"

        asked << args
        pages.shift || { "entries" => [] }
      end
      asked
    end
end
