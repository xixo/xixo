require "test_helper"

class BrowserAccessTest < ActionDispatch::IntegrationTest
  ORIGIN = "http://localhost:6274".freeze

  setup do
    @tenant = Tenant.create!(subdomain: "browser-#{SecureRandom.hex(4)}", name: "Browser")
    connect!(@tenant)
    host! "#{@tenant.subdomain}.xixo.test"
  end

  test "a page on another origin reads the protected resource metadata" do
    %w[/.well-known/oauth-protected-resource /.well-known/oauth-protected-resource/mcp].each do |path|
      get path, headers: { "Origin" => ORIGIN }

      assert_response :success
      assert_equal "*", response.headers["access-control-allow-origin"], path
    end
  end

  test "an MCP client in a browser reads the challenge that sends it to sign in" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
                 headers: { "Origin" => ORIGIN, "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_equal "*", response.headers["access-control-allow-origin"]
    assert_includes response.headers["access-control-expose-headers"], "WWW-Authenticate"
    assert_includes response.headers["access-control-expose-headers"], "Mcp-Session-Id"
  end

  test "the MCP endpoint answers a preflight that names its session and version headers" do
    process :options, "/mcp", headers: {
      "Origin" => ORIGIN,
      "Access-Control-Request-Method" => "POST",
      "Access-Control-Request-Headers" => "authorization, content-type, mcp-session-id, mcp-protocol-version"
    }

    assert_response :no_content
    assert_equal "*", response.headers["access-control-allow-origin"]
    %w[Authorization Mcp-Session-Id Mcp-Protocol-Version].each do |header|
      assert_includes response.headers["access-control-allow-headers"], header
    end
    assert_includes response.headers["access-control-allow-methods"], "DELETE"
  end

  test "the app's own pages and requests with no origin carry no grant" do
    get "/auth", headers: { "Origin" => ORIGIN }
    assert_nil response.headers["access-control-allow-origin"]

    post "/graphql", params: { query: "{ __typename }" }, headers: { "Origin" => ORIGIN }
    assert_nil response.headers["access-control-allow-origin"]

    get "/.well-known/oauth-protected-resource"
    assert_nil response.headers["access-control-allow-origin"]
  end
end
