require_relative "test_helper"

class EmbeddedIssuerTest < EmbeddedTest
  test "masks answers at /id on xixo's own origin" do
    get "/id/.well-known/openid-configuration"

    assert_response :success
    assert_equal ISSUER, json["issuer"]
    assert_equal "#{ISSUER}/token", json["token_endpoint"]
  end

  test "the authorization server metadata is also found where RFC 8414 puts it" do
    EmbeddedIssuer::INSERTED.each do |path|
      get "#{path}/id"

      assert_response :success
      assert_equal ISSUER, json["issuer"], path
    end
  end

  test "the MCP endpoint names the embedded issuer as its authorization server" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_equal [ ISSUER ], json["authorization_servers"]
    assert_equal "#{ORIGIN}/mcp", json["resource"]
  end

  test "xixo names the same issuer masks does" do
    get "/id/.well-known/openid-configuration"

    assert_equal json["issuer"], Tenant.issuer_url(request)
  end

  test "xixo reads its issuer inside the process, with no socket" do
    discovery = Masks::Client::Issuer.new(ISSUER).discovery

    assert_equal ISSUER, discovery["issuer"]
    assert_equal "xixo", discovery.dig("tenant", "subdomain")
    assert_not_empty Masks::Client::Issuer.new(ISSUER).jwks["keys"]
  end

  test "only xixo's own origin is answered inside the process" do
    assert EmbeddedIssuer.serves?(URI("#{ISSUER}/token"))
    assert_not EmbeddedIssuer.serves?(URI("#{ORIGIN}/mcp"))
    assert_not EmbeddedIssuer.serves?(URI("#{ORIGIN}/identity"))

    ENV["XIXO_PUBLIC_ORIGIN"] = ORIGIN

    assert EmbeddedIssuer.serves?(URI("#{ISSUER}/token"))
    assert_not EmbeddedIssuer.serves?(URI("https://elsewhere.test/id/token"))
    assert_not EmbeddedIssuer.serves?(URI("http://xixo.test/id/token"))
    assert_not EmbeddedIssuer.serves?(URI("https://xixo.test:8443/id/token"))
  ensure
    ENV.delete("XIXO_PUBLIC_ORIGIN")
  end

  test "masks keeps its session in a cookie of its own" do
    get "/id/login"

    assert_response :success
    assert cookies["_masks_session"].present?
  end

  test "masks' assets are served beside it" do
    get "/id/login"

    asset = response.body[%r{/masks-assets/[^"]+\.js}]

    assert asset, "the sign-in page names a script"

    get asset

    assert_response :success
  end
end
