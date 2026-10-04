require "test_helper"

class SignInTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(subdomain: "signin-#{SecureRandom.hex(4)}", name: "Sign in")
    connect!(@tenant)

    Tenant.switch(@tenant) { @item = create_feed(mime: "application/pdf", title: "An invoice") }
  end

  test "starting a sign-in redirects to this tenant's issuer with pkce" do
    get "/auth", headers: host

    assert_response :redirect

    query = Rack::Utils.parse_query(URI.parse(response.location).query)

    assert response.location.start_with?(issuer.url_for(@tenant.subdomain))
    assert_equal "code", query["response_type"]
    assert_equal "S256", query["code_challenge_method"]
    assert query["state"].present?
    assert query["nonce"].present?
    assert_includes query["scope"].split, "xixo:catalog:read"
    assert_equal "http://#{@tenant.subdomain}.xixo.test/mcp", query["resource"]
    assert_not_includes response.location, "code_verifier"
  end

  test "the callback exchanges the code and establishes a session" do
    sign_in

    assert_response :redirect
    assert_equal "http://#{@tenant.subdomain}.xixo.test/", response.location
  end

  test "the session endpoint answers who is signed in" do
    sign_in

    get "/auth/session", headers: host

    assert_response :success

    account = response.parsed_body

    assert_equal true, account["signed_in"]
    assert_equal "owner", account["nickname"]
    assert_equal "owner@example.invalid", account["email"]
    assert_equal @tenant.subdomain, account.dig("tenant", "subdomain")
    assert_includes account["scopes"], "xixo:catalog:read"
    assert_nil account["access_token"], "a token must never reach the browser"
  end

  test "the session endpoint refuses a browser that has not signed in" do
    get "/auth/session", headers: host

    assert_response :unauthorized
    assert_equal false, response.parsed_body["signed_in"]
    assert_equal "/auth/", response.parsed_body["login_url"]
  end

  test "a signed-in browser queries graphql on the cookie alone" do
    sign_in

    post "/graphql", params: { query: "{ feeds { nodes { title } } }" }, headers: host

    assert_response :success
    assert_equal [ { "title" => "An invoice" } ],
                 response.parsed_body.dig("data", "feeds", "nodes")
  end

  test "the session fits in a cookie, because three JWTs do not" do
    sign_in

    held = cookies["_xixo_session"].to_s

    assert held.present?
    assert_operator held.bytesize, :<, 4096,
                    "the id token must not be kept once its claims are read"

    get "/auth/session", headers: host

    assert_equal "owner", response.parsed_body["nickname"],
                 "dropping the id token must not drop who is signed in"
  end

  test "a callback whose state does not match this browser starts sign-in again once, then is refused" do
    get "/auth", headers: host
    granted = issuer.authorize!(response.location)

    get "/auth/callback", params: { code: granted[:code], state: "forged" }, headers: host

    assert_redirected_to "/auth/"
    assert_no_session

    get "/auth/callback", params: { code: granted[:code], state: "forged" }, headers: host

    assert_response :bad_request
    assert_no_session
  end

  test "a callback with no authorization in flight starts sign-in again rather than ending there" do
    get "/auth/callback", params: { code: "abc", state: "whatever" }, headers: host

    assert_redirected_to "/auth/"
    assert_no_session
  end

  test "a callback opened again once signed in, as a restored tab does, goes on to the app" do
    get "/auth", headers: host
    granted = issuer.authorize!(response.location)
    get "/auth/callback", params: { code: granted[:code], state: granted[:state] }, headers: host
    signed_in_to = response.location

    get "/auth/callback", params: { code: granted[:code], state: granted[:state] }, headers: host

    assert_redirected_to signed_in_to
    get "/auth/session", headers: host
    assert_response :success
  end

  test "the issuer refusing the code leaves no session behind" do
    get "/auth", headers: host
    granted = issuer.authorize!(response.location)

    get "/auth/callback", params: { code: "never-issued", state: granted[:state] }, headers: host

    assert_response :bad_request
    assert_no_session
  end

  test "a code redeemed twice fails the second time" do
    get "/auth", headers: host
    granted = issuer.authorize!(response.location)

    get "/auth/callback", params: { code: granted[:code], state: granted[:state] }, headers: host
    assert_response :redirect

    get "/auth", headers: host
    second = issuer.authorize!(response.location)

    get "/auth/callback", params: { code: granted[:code], state: second[:state] }, headers: host

    assert_response :bad_request
  end

  test "only somebody who can change everyone's settings can reconnect a connected xixo" do
    sign_in(scopes: %w[xixo:catalog:read xixo:settings:admin])
    get "/auth/handshake", headers: host

    assert_response :success

    delete "/auth/logout", headers: host
    sign_in(scopes: %w[xixo:catalog:read xixo:settings:write])
    get "/auth/handshake", headers: host

    assert_response :forbidden
  end

  test "signing out drops the session" do
    sign_in

    delete "/auth/logout", headers: host

    assert_no_session
  end

  test "the scopes the session carries are the ones the issuer granted" do
    sign_in(scopes: %w[xixo:catalog:read])

    get "/auth/session", headers: host

    assert_equal [ "xixo:catalog:read" ], response.parsed_body["scopes"] & Grant::SCOPES

    post "/graphql",
         params: { query: "mutation($id: ID!) { analyzeFeed(input: { id: $id }) { analysis { id status } } }",
                   variables: { id: @item.id.to_s } },
         headers: host

    assert_match(/does not carry xixo:catalog:write/,
                 response.parsed_body.dig("errors", 0, "message"))
  end

  private

    def host
      { "HOST" => "#{@tenant.subdomain}.xixo.test" }
    end

    def sign_in(scopes: Grant::SCOPES)
      get "/auth", headers: host
      granted = issuer.authorize!(response.location, scopes: scopes)

      get "/auth/callback",
          params: { code: granted[:code], state: granted[:state] }, headers: host
    end

    def assert_no_session
      get "/auth/session", headers: host

      assert_response :unauthorized
    end
end
