require "test_helper"
require "masks/client/delegations/fake"

class ResourceMcpTest < ActiveSupport::TestCase
  LISTED = [
    { "name" => "web_search", "description" => "Search the web",
      "input_schema" => { "properties" => { "query" => { "type" => "string" } },
                          "required" => [ "query" ] } }
  ].freeze

  setup do
    @tenant = Tenant.create!(subdomain: "mcp-#{SecureRandom.hex(4)}", name: "Servers")
  end

  def server(**details)
    Tenant.switch(@tenant) do
      Resource::Mcp.create!(
        key: "exa", name: "Exa",
        details: { "url" => "https://example.com/mcp", "auth" => "bearer" }.merge(details),
        credentials: { "token" => "sk-test" }
      )
    end
  end

  def discovered
    server(**{ "tools" => LISTED })
  end

  test "a server with no address cannot be reached, so it is refused" do
    Tenant.switch(@tenant) do
      assert_not Resource::Mcp.new(key: "exa").valid?
    end
  end

  test "a key that could not prefix a tool name is refused" do
    Tenant.switch(@tenant) do
      held = Resource::Mcp.new(key: "Not A Key", details: { "url" => "https://a.test/mcp" })

      assert_not held.valid?
      assert_match(/prefix a tool/, held.errors.full_messages.join)
    end
  end

  test "a server pointing back at xixo is refused rather than left to call itself" do
    with_suffix("xixo.localhost") do
      Tenant.switch(@tenant) do
        held = Resource::Mcp.new(key: "loop", details: { "url" => "https://demo.xixo.localhost/mcp" })

        assert_not held.valid?
        assert_match(/points back at xixo/, held.errors.full_messages.join)
      end
    end
  end

  test "its tools are offered under its own key, so two servers cannot collide" do
    Tenant.switch(@tenant) do
      proxied = discovered.proxied_tools

      assert_equal 1, proxied.size
      assert_equal "exa__web_search", proxied.first.tool_name
      assert_equal Resource::Mcp::SCOPE, proxied.first.scope
      assert_equal "Search the web", proxied.first.description
      assert_equal({ "query" => { "type" => "string" } },
                   proxied.first.input_schema.to_h.deep_stringify_keys["properties"])
    end
  end

  test "a server that has never been checked offers nothing rather than guessing" do
    Tenant.switch(@tenant) { assert_empty server.proxied_tools }
  end

  test "a grant carrying the scope is offered the proxied tools alongside the built-in ones" do
    discovered

    offered = Tenant.switch(@tenant) { grant(Grant::SCOPES).tools.map(&:tool_name) }

    assert_includes offered, "exa__web_search"
    assert_includes offered, "search"
  end

  test "a grant without the scope is offered none of them" do
    discovered

    offered = Tenant.switch(@tenant) { grant([ "xixo:catalog:read" ]).tools.map(&:tool_name) }

    assert_not_includes offered, "exa__web_search"
  end

  test "a server carries what its authentication sends, and nothing it does not" do
    Tenant.switch(@tenant) do
      built = ->(auth, credentials, **details) do
        Resource::Mcp.new(key: "m", details: { "url" => "https://a.test/mcp", "auth" => auth, **details.transform_keys(&:to_s) },
                          credentials: credentials)
      end

      assert built.call("basic", { "username" => "u", "password" => "p" }).valid?
      assert built.call("header", { "header_value" => "v" }, header_name: "X-API-Key").valid?
      assert built.call("none", {}).valid?

      assert_not built.call("bearer", { "token" => "t", "username" => "u" }).valid?, "a stray username"
      assert_not built.call("basic", { "password" => "p" }).valid?, "a password with no username"
      assert_not built.call("header", { "header_value" => "v" }).valid?, "a header with no name"
      assert_not built.call("digest", {}).valid?, "an authentication nothing sends"
    end
  end

  test "a header of its own cannot be one the connection sets, or run onto another line" do
    Tenant.switch(@tenant) do
      %w[Host Content-Length Mcp-Session-Id Proxy-Authorization Cookie X\ Key].each do |name|
        held = Resource::Mcp.new(key: "m", details: { "url" => "https://a.test/mcp", "auth" => "header", "header_name" => name },
                                 credentials: { "header_value" => "v" })

        assert_not held.valid?, "#{name} is not a header it may send"
      end

      smuggled = Resource::Mcp.new(key: "m", details: { "url" => "https://a.test/mcp", "auth" => "header", "header_name" => "X-Key" },
                                   credentials: { "header_value" => "v\r\nHost: elsewhere" })

      assert_not smuggled.valid?
      assert_match(/another line/, smuggled.errors.full_messages.join)
    end
  end

  test "credentials are not sent to a public server over plain http" do
    Tenant.switch(@tenant) do
      plain = server(**{ "url" => "http://mcp.example.test/mcp", "tools" => LISTED })

      error = assert_raises(PublicFetch::Blocked) { plain.invoke!("web_search", { query: "x" }) }
      assert_match(/plain http/, error.message)
    end
  end

  test "a server on the private network may take credentials over plain http where that is allowed" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    Tenant.switch(@tenant) do
      local = server(**{ "url" => "http://127.0.0.1:1/mcp", "tools" => LISTED })

      error = assert_raises(Resource::Failed) { local.invoke!("web_search", { query: "x" }) }
      assert_no_match(/plain http/, error.message)
    end
  ensure
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "a private address is blocked before any tool is called" do
    Tenant.switch(@tenant) do
      inside = server(**{ "url" => "http://127.0.0.1:9200/mcp", "tools" => LISTED })

      assert_raises(PublicFetch::Blocked) { inside.invoke!("web_search", { query: "x" }) }
    end
  end

  test "a private server whose origin is named in XIXO_MCP_ORIGINS is reached, and no other private address is" do
    ENV["XIXO_MCP_ORIGINS"] = "http://127.0.0.1:1, https://mcp.internal"

    Tenant.switch(@tenant) do
      named = server(**{ "url" => "http://127.0.0.1:1/mcp", "tools" => LISTED })
      error = assert_raises(Resource::Failed) { named.invoke!("web_search", { query: "x" }) }
      assert_not_kind_of PublicFetch::Blocked, error

      named.update!(details: named.details.merge("url" => "http://127.0.0.1:9200/mcp"))
      assert_raises(PublicFetch::Blocked) { named.invoke!("web_search", { query: "x" }) }
    end
  ensure
    ENV.delete("XIXO_MCP_ORIGINS")
  end

  test "a server authenticated through masks names its provider, and holds nothing typed in" do
    Tenant.switch(@tenant) do
      held = Resource::Mcp.new(key: "notion", details: { "url" => "https://mcp.notion.com/mcp", "auth" => "masks", "provider" => "notion" })

      assert held.valid?, held.errors.full_messages.to_sentence
      assert held.delegated?
      assert held.needs_connect?
      assert_equal "notion", held.provider_key

      assert_not Resource::Mcp.new(key: "n", details: { "url" => "https://a.test/mcp", "auth" => "masks" }).valid?
      assert_not Resource::Mcp.new(key: "n", details: { "url" => "https://a.test/mcp", "auth" => "masks", "provider" => "notion" },
                                   credentials: { "token" => "pasted" }).valid?, "a pasted token beside masks"
      refute server.needs_connect?, "a pasted bearer token needs nobody to connect anything"
    end
  end

  test "a server authenticated through masks is called with the token masks releases, and a refused one is replaced once" do
    masks = Delegations.fake = Masks::Client::Delegations::Fake.new
    started = masks.start(provider: "notion")
    held = masks.finish(params: masks.approve(started, subject: "ada", connection: "c-n"), started: started)

    resource = Tenant.switch(@tenant) do
      Resource::Mcp.create!(key: "notion", details: { "url" => "https://mcp.notion.test/mcp", "auth" => "masks", "provider" => "notion", "tools" => LISTED })
        .tap { |made| made.connect!(held, by: "ada") }
    end

    bearers = []

    stub_request(:post, "https://mcp.notion.test/mcp").to_return do |request|
      bearers << request.headers["Authorization"]
      rpc = JSON.parse(request.body)

      next { status: 401, body: "" } if bearers.last == "Bearer notion-access-1" && rpc["method"] == "tools/call"

      answered = case rpc["method"]
      when "initialize"
        { "protocolVersion" => "2025-06-18", "capabilities" => { "tools" => {} }, "serverInfo" => { "name" => "notion", "version" => "1" } }
      when "tools/call"
        { "content" => [ { "type" => "text", "text" => "found it" } ] }
      end

      next { status: 202, body: "" } if answered.nil?

      { status: 200, headers: { "Content-Type" => "application/json" }, body: { "jsonrpc" => "2.0", "id" => rpc["id"], "result" => answered }.to_json }
    end

    relayed = Tenant.switch(@tenant) { resource.invoke!("web_search", { query: "plans" }) }

    assert_equal "found it", relayed.content.first["text"]
    assert_includes bearers, "Bearer notion-access-1"
    assert_equal "Bearer notion-access-2", bearers.last
    assert_equal 2, masks.releases
  ensure
    Delegations.fake = nil
  end

  test "a server authenticated through masks that nobody connected is unusable, not merely unreachable" do
    Tenant.switch(@tenant) do
      resource = Resource::Mcp.create!(key: "notion", details: { "url" => "https://mcp.notion.test/mcp", "auth" => "masks", "provider" => "notion", "tools" => LISTED })

      assert_raises(Resource::Unusable) { resource.invoke!("web_search", { query: "x" }) }
    end
  end

  test "pointing a server connected through masks somewhere else forgets whose account it held" do
    Tenant.switch(@tenant) do
      resource = Resource::Mcp.create!(key: "notion", connected_by: "ada",
                                       details: { "url" => "https://mcp.notion.test/mcp", "auth" => "masks", "provider" => "notion" },
                                       credentials: { "delegation" => { "secret" => "s", "connection" => "c" },
                                                      "upstream" => { "access_token" => "adas-token" } })

      resource.update!(details: resource.details.merge("url" => "https://elsewhere.test/mcp"))

      assert_empty resource.reload.credentials
      assert_nil resource.connected_by
      assert resource.needs_connect?
    end
  end

  test "switching away from masks forgets what masks held" do
    Tenant.switch(@tenant) do
      resource = Resource::Mcp.create!(key: "notion", details: { "url" => "https://mcp.notion.test/mcp", "auth" => "masks", "provider" => "notion" },
                                       credentials: { "delegation" => { "secret" => "s", "connection" => "c" } })

      resource.update!(details: resource.details.merge("auth" => "bearer"), credentials: resource.credentials.merge("token" => "pasted"))

      assert_equal({ "token" => "pasted" }, resource.reload.credentials)
    end
  end

  private

    def grant(scopes)
      Grant.new(tenant: @tenant,
                claims: Masks::Client::Claims.new("sub" => "t", "scope" => scopes.join(" ")))
    end

    def with_suffix(suffix)
      previous = ENV["XIXO_HOST_SUFFIX"]
      ENV["XIXO_HOST_SUFFIX"] = suffix
      yield
    ensure
      ENV["XIXO_HOST_SUFFIX"] = previous
    end
end
