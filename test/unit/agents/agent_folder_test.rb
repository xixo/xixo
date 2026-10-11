require "test_helper"
require_relative "../../support/machines"

class AgentFolderTest < ActiveSupport::TestCase
  include Machines

  setup do
    @tenant = Tenant.create!(subdomain: "folders-#{SecureRandom.hex(4)}", name: "Folders")
    @agent = agent_on(@tenant, folders: [ "/srv/media", "/srv/photos" ])
  end

  test "a folder is attached only through an agent, and only one the agent shares" do
    Tenant.switch(@tenant) do
      held = Resource::AgentFolder.new(key: "media", details: { "folder" => "/srv/media" }, via: @agent)
      assert held.valid?, held.errors.full_messages.to_sentence

      elsewhere = Resource::AgentFolder.new(key: "etc", details: { "folder" => "/etc" }, via: @agent)
      assert_not elsewhere.valid?
      assert_match(%r{/etc is not one the agent on box shares. It shares /srv/media and /srv/photos}, elsewhere.errors.full_messages.to_sentence)

      direct = Resource::AgentFolder.new(key: "direct", details: { "folder" => "/srv/media" })
      assert_not direct.valid?

      tailnet = Resource::Tailnet.create!(key: "tailnet")
      through_tailnet = Resource::AgentFolder.new(key: "far", details: { "folder" => "/srv/media" }, via: tailnet)
      assert_not through_tailnet.valid?
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
      first = folder.locator_for(Resource::AgentFolder::Entry.new(path: "a", size: 5, modified_at: Time.utc(2026, 10, 11, 12)))
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

  test "a folder the agent stopped sharing is not asked for" do
    Tenant.switch(@tenant) do
      folder = attached
      folder.agent.details = folder.agent.details.merge("machine" => folder.agent.machine.merge("folders" => [ "/srv/photos" ]))
      asked = answering(folder, [])

      error = assert_raises(Resource::Unusable) { folder.each_page { |*| nil } }
      assert_match(%r{no longer shares /srv/media}, error.message)
      assert_raises(Resource::Unusable) { folder.download({ "path" => "a.txt" }) }
      assert_empty asked
    end
  end

  test "the agent offers its folders to attach" do
    Tenant.switch(@tenant) do
      offered = @agent.discovered(services: true)

      assert_equal %w[media photos], offered.map { |node| node["host_name"] }
      assert_equal [ "/srv/media" ], offered.first["services"].map { |service| service["address"] }
      assert_equal [ "agent-folder" ], offered.first["services"].map { |service| service["type"] }
    end
  end

  private

    def attached
      Resource::AgentFolder.create!(key: "media-#{SecureRandom.hex(2)}", details: { "folder" => "/srv/media" }, via: @agent)
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
