require "test_helper"

class TransportsTest < ActionDispatch::IntegrationTest
  TYPES = <<~GQL.freeze
    { resourceTypes { type routable } }
  GQL

  ATTACH = <<~GQL.freeze
    mutation($type: String!, $key: String!, $settings: JSON, $via: String) {
      attachResource(input: { type: $type, key: $key, settings: $settings, via: $via }) {
        resource { key via routable }
        checkError
      }
    }
  GQL

  UPDATE = <<~GQL.freeze
    mutation($id: ID!, $via: String) {
      updateResource(input: { id: $id, via: $via }) {
        resource { key via }
      }
    }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "transports-#{SecureRandom.hex(4)}", name: "Transports")
    connect!(@tenant)

    Tenant.switch(@tenant) { @tailnet = Resource::Tailnet.create!(key: "tailnet", name: "Tailnet") }
  end

  teardown do
    ENV.delete("URIS_TAILSCALE_SOCKET")
  end

  test "each type says whether it can be reached through a transport" do
    routable = execute(TYPES).dig("data", "resourceTypes").to_h { |held| [ held["type"], held["routable"] ] }

    assert routable.fetch("webdav")
    assert routable.fetch("s3")
    refute routable.fetch("weather")
    refute_includes routable.keys, "tailnet"
  end

  test "a resource attached through a transport names it, and its check reaches the transport first" do
    attached = attach("shares", via: "tailnet").dig("data", "attachResource")

    assert_equal "tailnet", attached.dig("resource", "via")
    assert attached.dig("resource", "routable")
    assert_match(/shares is reached through tailnet, which is down/, attached["checkError"])
  end

  test "a transport that is not here is refused" do
    body = attach("shares", via: "elsewhere")

    assert_equal "elsewhere is not a transport here", body.dig("errors", 0, "message")
    Tenant.switch(@tenant) { assert_nil Resource.find_by(key: "shares") }
  end

  test "a resource that is not a transport is refused as one" do
    Tenant.switch(@tenant) { Resource::Webdav.create!(key: "first", details: { "url" => "https://dav.example.test/" }) }

    body = attach("second", via: "first")

    assert_equal "first is not a transport here", body.dig("errors", 0, "message")
  end

  test "an update moves a resource onto a transport and off it again" do
    shares = Tenant.switch(@tenant) { Resource::Webdav.create!(key: "shares", details: { "url" => "http://100.64.1.2/dav/" }) }

    moved = execute(UPDATE, variables: { id: shares.id, via: "tailnet" }).dig("data", "updateResource", "resource")
    assert_equal "tailnet", moved["via"]

    kept = execute(UPDATE, variables: { id: shares.id }).dig("data", "updateResource", "resource")
    assert_equal "tailnet", kept["via"]

    direct = execute(UPDATE, variables: { id: shares.id, via: "" }).dig("data", "updateResource", "resource")
    assert_nil direct["via"]
  end

  private

    def attach(key, via:)
      execute(ATTACH, variables: {
        type: "webdav", key: key, via: via, settings: { "url" => "http://100.64.1.2/dav/" }
      })
    end

    def execute(query, variables: nil)
      token = issuer.mint(
        subdomain: @tenant.subdomain, scopes: Grant::SCOPES,
        audience: "http://#{@tenant.subdomain}.uris.test/mcp"
      )

      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: { "HOST" => "#{@tenant.subdomain}.uris.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
