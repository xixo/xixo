require "test_helper"

class McpProxyTest < ActionDispatch::IntegrationTest
  include McpClient

  ALL = Grant::SCOPES
  LISTED = [
    { "name" => "web_search", "description" => "Search the web",
      "input_schema" => { "properties" => { "query" => { "type" => "string" } },
                          "required" => [ "query" ] } }
  ].freeze

  setup do
    SearchIndex.reset!
    Rails.cache.clear
    McpTransports.reset!

    @tenant = Tenant.create!(subdomain: "prx-#{SecureRandom.hex(4)}", name: "Proxied")
  end

  def attach(auth: "bearer", credentials: { "token" => "sk-test" }, **details)
    Tenant.switch(@tenant) do
      Resource::Mcp.create!(key: "exa", name: "Exa", credentials: credentials,
                            details: { "url" => "https://example.com/mcp", "tools" => LISTED, "auth" => auth,
                                       **details.transform_keys(&:to_s) })
    end
  end

  test "a proxied tool is listed under the resource's key" do
    attach

    listed = call(@tenant, ALL, "tools/list").dig("result", "tools").map { |tool| tool["name"] }

    assert_includes listed, "exa__web_search"
    assert_includes listed, "search"
  end

  test "the server is dialled at the address it was vetted at, not wherever its name points next" do
    attach
    speaks(text: "pinned")
    dialled = []
    recorder = Module.new do
      define_method(:request) do |*args, **options, &block|
        dialled << instance_variable_get(:@ipaddr) if address == "example.com"
        super(*args, **options, &block)
      end
    end
    Net::HTTP.prepend(recorder)

    call(@tenant, ALL, "tools/call", name: "exa__web_search", arguments: { query: "x" })

    assert_equal [ Offline::PUBLIC ], dialled.uniq
  ensure
    recorder&.send(:define_method, :request) { |*args, **options, &block| super(*args, **options, &block) }
  end

  test "a bearer token is sent as one" do
    attach
    speaks(text: "ok")

    relayed("anything")

    assert_requested(:post, "https://example.com/mcp", headers: { "Authorization" => "Bearer sk-test" }, at_least_times: 1)
  end

  test "a server behind basic auth is sent the username and password on every request" do
    attach(auth: "basic", credentials: { "username" => "reader", "password" => "pa:ss" })
    speaks(text: "behind the gate")

    assert_equal "behind the gate", relayed("anything").dig("result", "content", 0, "text")
    assert_requested(:post, "https://example.com/mcp",
                     headers: { "Authorization" => "Basic #{Base64.strict_encode64('reader:pa:ss')}" }, at_least_times: 2)
    assert_not_requested(:post, "https://example.com/mcp", headers: { "Authorization" => "Bearer sk-test" })
  end

  test "a server that wants a header of its own is sent that header and no Authorization" do
    attach(auth: "header", credentials: { "header_value" => "key-123" }, header_name: "X-API-Key")
    speaks(text: "keyed")

    relayed("anything")

    assert_requested(:post, "https://example.com/mcp", headers: { "X-API-Key" => "key-123" }, at_least_times: 2)
    assert_not_requested(:post, "https://example.com/mcp") { |request| request.headers.key?("Authorization") }
  end

  test "calling it forwards to the server and hands back what it said" do
    attach
    speaks(text: "a page about anything")

    reply = relayed("anything")

    assert_not reply.dig("result", "isError")
    assert_equal [ { "type" => "text", "text" => "a page about anything" } ], reply.dig("result", "content")
  end

  test "an image, an embedded resource and structured content come back as the server sent them" do
    attach
    parts = [
      { type: "text", text: "two results" },
      { type: "image", data: Base64.strict_encode64("png"), mimeType: "image/png" },
      { type: "resource", resource: { uri: "notion://page/1", mimeType: "text/markdown", text: "# One" } },
      { type: "resource_link", uri: "notion://page/2", name: "Two" },
      { type: "mystery", payload: "dropped" }
    ]
    speaks(result: { content: parts, structuredContent: { "hits" => 2 } })

    reply = relayed("anything")

    assert_equal %w[text image resource resource_link], reply.dig("result", "content").pluck("type")
    assert_equal "image/png", reply.dig("result", "content", 1, "mimeType")
    assert_equal "# One", reply.dig("result", "content", 2, "resource", "text")
    assert_equal({ "hits" => 2 }, reply.dig("result", "structuredContent"))
  end

  test "what a server says about its own tools is passed on with them" do
    attach(tools: [ LISTED.first.merge("annotations" => { "readOnlyHint" => true, "title" => "Search the web",
                                                          "destructiveHint" => "maybe" }) ])

    listed = call(@tenant, ALL, "tools/list").dig("result", "tools").find { |tool| tool["name"] == "exa__web_search" }

    assert_equal true, listed.dig("annotations", "readOnlyHint")
    assert_equal "Search the web", listed.dig("annotations", "title")
    assert_equal true, listed.dig("annotations", "destructiveHint"), "a hint that is not a boolean is not believed"
  end

  test "calls to one server share a session rather than shaking hands every time" do
    attach
    asked = speaks_in_session

    3.times { relayed("anything") }

    assert_equal 1, asked.count("initialize")
    assert_equal 3, asked.count("tools/call")
  end

  test "a server whose credentials change is met with a new session" do
    resource = attach
    asked = speaks_in_session

    relayed("anything")
    Tenant.switch(@tenant) { resource.update!(credentials: { "token" => "sk-rotated" }) }
    @mcp_sessions = nil
    relayed("anything")

    assert_equal 2, asked.count("initialize")
    assert_requested(:post, "https://example.com/mcp", headers: { "Authorization" => "Bearer sk-rotated" }, at_least_times: 2)
  end

  test "a session the server ended is started again and the call still answers" do
    attach
    asked = speaks_in_session(expire_after: 1)

    relayed("first")
    reply = relayed("second")

    assert_not reply.dig("result", "isError"), reply.dig("result", "content", 0, "text")
    assert_equal 2, asked.count("initialize")
  end

  test "a server that answers an error says so on the call, not on the tool list" do
    attach
    speaks(text: "upstream is down", failed: true)

    reply = call(@tenant, ALL, "tools/call",
                 name: "exa__web_search", arguments: { query: "anything" })

    assert reply.dig("result", "isError")
    assert_match(/upstream is down/, reply.dig("result", "content", 0, "text"))
  end

  test "a server that will not answer at all is a failure, not a hang" do
    attach
    stub_request(:post, "https://example.com/mcp").to_return(status: 502, body: "nope")

    reply = call(@tenant, ALL, "tools/call",
                 name: "exa__web_search", arguments: { query: "anything" })

    assert reply.dig("result", "isError")
  end

  test "attaching a server changes what tools/list answers rather than serving a stale one" do
    before = call(@tenant, ALL, "tools/list").dig("result", "tools").map { |tool| tool["name"] }

    assert_not_includes before, "exa__web_search"

    attach
    @mcp_sessions = nil

    after = call(@tenant, ALL, "tools/list").dig("result", "tools").map { |tool| tool["name"] }

    assert_includes after, "exa__web_search"
  end

  test "a token without the scope is not offered another server's tools" do
    attach

    listed = call(@tenant, [ "xixo:catalog:read" ], "tools/list")
             .dig("result", "tools").map { |tool| tool["name"] }

    assert_not_includes listed, "exa__web_search"
  end

  private

    def speaks_in_session(expire_after: nil)
      asked = []
      calls = 0

      stub_request(:post, "https://example.com/mcp").to_return do |request|
        body = JSON.parse(request.body)
        asked << body["method"]
        calls += 1 if body["method"] == "tools/call"

        if expire_after && body["method"] == "tools/call" && calls == expire_after + 1
          next { status: 404, body: "" }
        end

        { status: 200, headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-#{asked.count('initialize')}" },
          body: replied(body, "in session", false, nil).to_json }
      end

      asked
    end

    def relayed(query)
      call(@tenant, ALL, "tools/call", name: "exa__web_search", arguments: { query: query })
    end

    def speaks(text: nil, failed: false, result: nil)
      stub_request(:post, "https://example.com/mcp").to_return do |request|
        asked = JSON.parse(request.body)

        { status: 200, headers: { "Content-Type" => "application/json" },
          body: replied(asked, text, failed, result).to_json }
      end
    end

    def replied(asked, text, failed, result)
      base = { jsonrpc: "2.0", id: asked["id"] }

      case asked["method"]
      when "initialize"
        base.merge(result: { protocolVersion: "2025-06-18", capabilities: { tools: {} },
                             serverInfo: { name: "exa", version: "1" } })
      when "tools/call"
        base.merge(result: result || { content: [ { type: "text", text: text } ], isError: failed })
      else
        base.merge(result: {})
      end
    end
end
