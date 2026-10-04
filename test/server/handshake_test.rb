require "test_helper"

class HandshakeTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(subdomain: "handshake-#{SecureRandom.hex(4)}", name: "Handshake")
  end

  test "an app nobody has connected walks into the handshake rather than a login it cannot run" do
    get "/", headers: host

    assert_redirected_to "/auth/handshake"

    get "/auth/handshake", headers: host

    assert_response :redirect
    assert response.location.start_with?("#{issuer.url_for(@tenant.subdomain)}/handshake")
  end

  test "starting the handshake sends the browser to its issuer, naming one origin throughout" do
    post "/auth/handshake", headers: host

    assert_response :redirect

    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    origin = "http://#{@tenant.subdomain}.xixo.test"

    assert response.location.start_with?("#{issuer.url_for(@tenant.subdomain)}/handshake")
    assert_equal "#{origin}/mcp", query["resource"]
    assert_equal "#{origin}/auth/handshake/callback", query["return_to"]
    assert_equal [ "#{origin}/auth/callback", "#{origin}/connect/callback" ], query["redirect_uris"]
    assert_includes query["scope"].split, Grant::NAMESPACE
    assert_includes query["scope"].split, "masks:delegate:",
                    "xixo asks each person for their accounts elsewhere, so its handshake says so"
    assert_not_includes query["scope"].split, "xixo:catalog:read",
                        "the handshake asks for the namespace; sign-in asks for the scopes"
    assert_includes query["scope"].split, "offline_access"
    assert query["state"].present?
  end

  test "the callback redeems the token and stores credentials nobody typed in" do
    get callback_for(state: start!), headers: host

    assert_redirected_to "/auth/"

    @tenant.reload

    assert @tenant.connected?
    assert @tenant.client_secret.present?
    assert @tenant.registration_access_token.present?
    assert @tenant.connected_at.present?
  end

  test "the credentials are encrypted at rest" do
    connect!(@tenant)

    stored = Tenant.connection.select_one(
      "SELECT client_secret, registration_access_token FROM tenants WHERE id = #{@tenant.id}"
    )

    assert_not_equal "items-test-secret", stored["client_secret"]
    assert_no_match(/items-test-secret/, stored.values.join)
  end

  test "a callback whose state does not match this browser redeems nothing" do
    start!

    get callback_for(state: "forged"), headers: host

    assert_response :bad_request
    assert_match "invalid_state", response.body
    assert_not @tenant.reload.connected?
  end

  test "a callback with no handshake in flight is refused" do
    get "/auth/handshake/callback?initial_access_token=whatever&state=whatever", headers: host

    assert_response :bad_request
    assert_not @tenant.reload.connected?
  end

  test "an answer from another issuer redeems nothing" do
    state = start!

    get callback_for(state: state, iss: "https://elsewhere.test"), headers: host

    assert_response :bad_request
    assert_match "invalid_issuer", response.body
    assert_not @tenant.reload.connected?
  end

  test "a refusal at the approval screen is carried through rather than shown as a crash" do
    state = start!

    get "/auth/handshake/callback?error=access_denied&error_description=declined&state=#{state}",
        headers: host

    assert_response :bad_request
    assert_match "access_denied", response.body
    assert_not @tenant.reload.connected?
  end

  test "a token the issuer will not honour leaves the app unconnected" do
    state = start!

    get "/auth/handshake/callback?initial_access_token=never-approved&state=#{state}" \
        "&iss=#{CGI.escape(issuer.url_for(@tenant.subdomain))}", headers: host

    assert_response :bad_request
    assert_match "invalid_token", response.body
    assert_not @tenant.reload.connected?
  end

  test "a token approved for another tenant does not connect this one" do
    other = Tenant.create!(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other")
    state = start!

    get callback_for(state: state, token: issuer.approve!(other.subdomain)), headers: host

    assert_response :bad_request
    assert_not @tenant.reload.connected?
  end

  test "a connected app does not offer the handshake to a browser that is not signed in" do
    connect!(@tenant)

    get "/auth/handshake", headers: host

    assert_redirected_to "/"

    post "/auth/handshake", headers: host

    assert_redirected_to "/"
  end

  test "the client credentials the sign-in flow uses come from the row" do
    get callback_for(state: start!), headers: host
    get "/auth", headers: host

    query = Rack::Utils.parse_query(URI.parse(response.location).query)

    assert_equal @tenant.reload.client_id, query["client_id"]
  end

  test "the session endpoint says an app is unconnected rather than offering a login" do
    get "/auth/session", headers: host.merge("HTTP_ACCEPT" => "application/json")

    assert_response :unauthorized

    body = JSON.parse(response.body)

    assert_equal "handshake_required", body["error"]
    assert_equal "/auth/handshake", body["handshake_url"]
  end

  test "a connected app nobody has signed into asks for a login instead" do
    connect!(@tenant)
    get "/auth/session", headers: host.merge("HTTP_ACCEPT" => "application/json")

    assert_response :unauthorized
    assert_equal "login_required", JSON.parse(response.body)["error"]
  end


  test "a connected tenant hands the engine everything RFC 7592 needs" do
    Tenant.switch(@tenant) do
      @tenant.update!(client_id: "cid", client_secret: "csec",
                      registration_access_token: "rat",
                      registration_client_uri: "https://auth.test/register/cid",
                      connected_at: Time.current)

      held = @tenant.masks_credentials

      assert_equal "rat", held[:registration_access_token]
      assert_equal "https://auth.test/register/cid", held[:registration_client_uri]
      assert Masks::Client::Registration.held("https://auth.test", held).present?,
             "a stored registration token nothing can spend is a token that is not stored"
    end
  end

  test "disconnecting drops every credential rather than only the pair" do
    Tenant.switch(@tenant) do
      @tenant.update!(client_id: "cid", client_secret: "csec",
                      registration_access_token: "rat",
                      registration_client_uri: "https://auth.test/register/cid",
                      connected_at: Time.current)

      @tenant.disconnect!

      assert_not @tenant.connected?
      assert_nil @tenant.registration_access_token
      assert_nil @tenant.registration_client_uri
      assert_nil @tenant.connected_at
    end
  end

  private

    def host
      { "HOST" => "#{@tenant.subdomain}.xixo.test" }
    end

    def start!
      post "/auth/handshake", headers: host

      Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    end

    def callback_for(state:, token: nil, iss: nil)
      query = {
        "initial_access_token" => token || issuer.approve!(@tenant.subdomain),
        "iss" => iss || issuer.url_for(@tenant.subdomain),
        "state" => state
      }

      "/auth/handshake/callback?#{Rack::Utils.build_query(query)}"
    end
end
