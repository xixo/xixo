require "test_helper"
require_relative "../support/fake_tailscaled"

class DiscoveryTest < ActionDispatch::IntegrationTest
  include McpClient

  SEEN = Time.utc(2026, 10, 9, 18, 30)

  DISCOVERED = <<~GQL.freeze
    query($via: String!) {
      discovered(via: $via) { hostName dnsName addresses online lastSeenAt webdav: address(type: "webdav") }
    }
  GQL

  RESOURCES = "{ resources { key healthy offline offlineHost offlineLastSeenAt checkError } }".freeze

  setup do
    @tailscaled = FakeTailscaled.new(peers: [
      FakeTailscaled.peer("nas", "100.64.1.2", online: false, last_seen: SEEN),
      FakeTailscaled.peer("studio", "100.64.1.3")
    ])
    ENV["XIXO_TAILSCALE_SOCKET"] = @tailscaled.path

    @tenant = Tenant.create!(subdomain: "discovery-#{SecureRandom.hex(4)}", name: "Discovery")
    Tenant.switch(@tenant) do
      @tailnet = Resource::Tailnet.create!(key: "tailnet", name: "Tailnet")
      Resource::Tailnet.create!(key: "adas", name: "Ada's", owner_subject: "ada")
      Resource::Curl.create!(key: "curl", name: "Curl")
    end
  end

  teardown do
    ENV.delete("XIXO_TAILSCALE_SOCKET")
    @tailscaled.stop
  end

  test "a transport offers the machines it reaches, with where each would be attached and nothing more" do
    nodes = execute(DISCOVERED, variables: { via: "tailnet" }).dig("data", "discovered")

    assert_equal [
      { "hostName" => "studio", "dnsName" => "studio.tail0000.ts.net", "addresses" => [ "100.64.1.3", "fd7a:115c:a1e0::3" ],
        "online" => true, "lastSeenAt" => nil, "webdav" => "http://100.64.1.3/" },
      { "hostName" => "nas", "dnsName" => "nas.tail0000.ts.net", "addresses" => [ "100.64.1.2", "fd7a:115c:a1e0::2" ],
        "online" => false, "lastSeenAt" => SEEN.iso8601, "webdav" => "http://100.64.1.2/" }
    ], nodes
  end

  test "a type no transport reaches has nowhere to put an address" do
    held = execute('{ discovered(via: "tailnet") { address(type: "weather") } }').dig("data", "discovered", 0)

    assert_equal({ "address" => nil }, held)
  end

  test "each attachable type names the field its address goes in" do
    types = execute("{ resourceTypes { type addressedBy } }").dig("data", "resourceTypes").to_h(&:values)

    assert_equal "url", types["webdav"]
    assert_equal "base_url", types["openai-compatible"]
    assert_equal "host", types["imap"]
    assert_nil types["weather"]
  end

  test "discovery is refused for a resource that is no transport, and for a transport somebody else keeps" do
    assert_equal "curl is not a transport here", execute(DISCOVERED, variables: { via: "curl" }).dig("errors", 0, "message")
    assert_equal "adas is not a transport here", execute(DISCOVERED, variables: { via: "adas" }).dig("errors", 0, "message")
  end

  test "discovery needs the scope that reads resources" do
    body = execute(DISCOVERED, variables: { via: "tailnet" }, scopes: %w[xixo:catalog:read])

    assert_nil body.dig("data", "discovered")
    assert body["errors"].present?
  end

  test "a resource on a machine that is offline reads offline, with the machine and when it was last seen" do
    Tenant.switch(@tenant) do
      Resource::Webdav.create!(key: "shares", details: { "url" => "http://100.64.1.2/dav/" }, via: @tailnet).check
    end

    shares = execute(RESOURCES).dig("data", "resources").find { |held| held["key"] == "shares" }

    assert_equal({ "key" => "shares", "healthy" => false, "offline" => true, "offlineHost" => "nas",
                   "offlineLastSeenAt" => SEEN.iso8601, "checkError" => nil }, shares)
  end

  test "the resource tool discovers through a transport and lists a resource that is offline" do
    Tenant.switch(@tenant) do
      Resource::Webdav.create!(key: "shares", details: { "url" => "http://100.64.1.2/dav/" }, via: @tailnet).check
    end

    Resource::Tailnet.singleton_class.alias_method(:really_listening?, :listening?)
    Resource::Tailnet.define_singleton_method(:listening?) { |_address, port| port == 993 }

    found = tool(@tenant, %w[xixo:resources:read], "resource", do: "discover", key: "tailnet")

    assert_equal "tailnet", found["transport"]
    assert_equal %w[studio nas], found["nodes"].map { |node| node["host_name"] }
    refute_match(/nodekey|tag:server/, found.to_json)
    assert_equal [ { "name" => "imaps", "port" => 993, "type" => "imap", "address" => "100.64.1.3" } ], found["nodes"].first["services"]

    listed = tool(@tenant, %w[xixo:resources:read], "resource")["resources"].find { |held| held["key"] == "shares" }
    assert_equal "nas is offline on tailnet, last seen 2026-10-09T18:30:00Z", listed["offline"]
  ensure
    Resource::Tailnet.singleton_class.alias_method(:listening?, :really_listening?)
  end

  private

    def execute(query, variables: nil, scopes: Grant::SCOPES)
      token = issuer.mint(
        subdomain: @tenant.subdomain, scopes: scopes,
        audience: "http://#{@tenant.subdomain}.xixo.test/mcp"
      )

      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
