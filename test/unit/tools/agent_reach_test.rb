require "test_helper"

class AgentReachTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "reach-#{SecureRandom.hex(4)}", name: "Reach")

    @allowed = Pathname(Dir.mktmpdir("reach"))
    @root = @allowed + @tenant.subdomain + "home"
    @root.mkpath
    @root.join("diary.txt").write("the safe code is 4417")
    ENV["XIXO_FILESYSTEM_ROOTS"] = @allowed.to_s

    Tenant.switch(@tenant) do
      Resource::Curl.create!(key: "curl", name: "Curl")
      Resource::Filesystem.create!(key: "home", name: "Home", details: { "root" => @root.to_s })
      @address = Feed.create!(type: Feed::ADDRESS, key: "/news", title: "News")
      @secret = Feed.create!(type: Feed::NOTE, key: "Safe", title: "Safe", note: "the safe code is 4417")
    end
  end

  teardown do
    Current.reset
    ENV.delete("XIXO_FILESYSTEM_ROOTS")
    FileUtils.rm_rf(@allowed)
  end

  test "an agent that has read the catalog cannot then reach the web" do
    running(Feed::AGENT_SCOPES) do
      assert_not called(Tool::Search, query: "safe").error?

      reply = called(Tool::Resources, key: "curl", do: "get", input: { url: "https://example.com/?q=4417" })

      assert reply.error?
      assert_match(/has read the catalog, so it can no longer reach the web/, text(reply))
    end
  end

  test "an agent that has read a place's files cannot then reach the web" do
    running(Feed::AGENT_SCOPES) do
      read = called(Tool::Resources, key: "home", do: "get", input: { key: "diary.txt" })
      assert_not read.error?, text(read)

      reply = called(Tool::Resources, key: "curl", do: "get", input: { url: "https://example.com/?q=4417" })

      assert_match(/can no longer reach the web/, text(reply))
    end
  end

  test "an agent that has read the web cannot then read the catalog or a place's files" do
    running(Feed::AGENT_SCOPES) do
      Current.grant.reaches!(:web)

      assert_match(/has read the web/, text(called(Tool::Search, query: "safe")))
      assert_match(/has read the web/, text(called(Tool::Feeds, id: @secret.id.to_s)))
      assert_match(/has read the web/, text(called(Tool::Resources, key: "home", do: "get", input: { key: "diary.txt" })))
      assert_match(/has read the web/, text(called(Tool::Connect, a: @address.id.to_s, b: @secret.id.to_s)))
    end
  end

  test "an agent that has read the web still keeps a note and files it under its own address" do
    running(Feed::AGENT_SCOPES) do
      Current.grant.reaches!(:web)

      made = JSON.parse(text(called(Tool::Feeds, do: "create", title: "Headline")))
      assert_not called(Tool::Feeds, do: "note", id: made["id"], note: "Read at example.com").error?
      assert_not called(Tool::Connect, a: made["id"], b: @address.id.to_s).error?
      assert_not called(Tool::Connect, a: made["id"], tag: "news").error?
    end
  end

  test "an agent's writes stay on its own feed and what it made" do
    running(Feed::AGENT_SCOPES) do
      reply = called(Tool::Feeds, do: "rename", id: @secret.id.to_s, title: "wiped")

      assert_match(/can only change what it made itself/, text(reply))
      assert_equal "Safe", @secret.reload.title
    end
  end

  test "a person's token reads the catalog and the web in one session" do
    Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "someone", "scope" => Grant::SCOPES.join(" ")))

    Tenant.switch(@tenant) do
      assert_not called(Tool::Search, query: "safe").error?
      assert Current.grant.reaches!(:web)
    end
  end

  test "filing an upload carries no web, and looking up the world carries no catalog" do
    Tenant.switch(@tenant) do
      assert_not @address.grant(scopes: Feed::FILING_SCOPES).permits?("xixo:web:read")
      assert_equal %w[resource], @address.grant(scopes: Feed::WORLD_SCOPES).tools.map(&:tool_name)
    end
  end

  private

    def running(scopes)
      Tenant.switch(@tenant) do
        Current.grant = @address.grant(scopes: scopes)
        Current.acting_for = @address.id
        Current.confined_to = Concurrent::Set.new([ @address.id ])
        yield
      end
    end

    def called(tool, **arguments)
      tool.call(server_context: {}, **arguments)
    end

    def text(reply)
      reply.content.first[:text]
    end
end
