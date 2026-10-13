require "test_helper"

class McpSessionTest < ActionDispatch::IntegrationTest
  include McpClient

  ALL = Grant::SCOPES

  setup do
    Rails.cache.clear
    McpTransports.reset!

    @tenant = Tenant.create!(subdomain: "sess-#{SecureRandom.hex(4)}", name: "Sessioned")
  end

  test "initialize issues a session id and the endpoint expects it back" do
    session = initialize_session(@tenant, ALL)

    assert session.present?

    send_rpc(@tenant, bearer(@tenant, ALL), "tools/list")

    assert_response :bad_request
    assert_match(/session/i, response.parsed_body.dig("error", "message"))
  end

  test "GET is refused, so no stream holds a server thread open" do
    held, session = session_for(@tenant, ALL)

    get "/mcp", headers: host_for(@tenant).merge(held)
                                          .merge("HTTP_ACCEPT" => "text/event-stream",
                                                 McpTransports::SESSION_HEADER => session)

    assert_response :method_not_allowed
    assert_equal "POST, DELETE", response.headers["Allow"]

    send_rpc(@tenant, held, "tools/list", nil, session: session)

    assert_response :success
  end

  test "a listen request is answered as a method xixo does not have, where it used to fail with a 500" do
    send_modern(@tenant, bearer(@tenant, ALL), "subscriptions/listen",
                { notifications: { toolsListChanged: true } })

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal(-32601, response.parsed_body.dig("error", "code"))
  end

  test "discovery promises no notifications, since xixo serves no listen stream" do
    send_modern(@tenant, bearer(@tenant, ALL), "server/discover")

    assert_response :success

    capabilities = response.parsed_body.dig("result", "capabilities")

    assert capabilities.key?("tools")
    assert_not capabilities.values.grep(Hash).any? { |flags| flags.key?("listChanged") || flags.key?("subscribe") }
  end

  test "DELETE ends the session, and it is not usable afterwards" do
    held, session = session_for(@tenant, ALL)

    delete "/mcp", headers: host_for(@tenant).merge(held)
                                             .merge(McpTransports::SESSION_HEADER => session)

    assert_response :success

    send_rpc(@tenant, held, "tools/list", nil, session: session)

    assert_response :not_found
  end

  test "a session is bound to the subject that opened it" do
    _held, session = session_for(@tenant, ALL)
    stranger = issuer.mint(subdomain: @tenant.subdomain, scopes: ALL, subject: "somebody-else",
                           audience: "#{origin_for(@tenant)}/mcp")

    send_rpc(@tenant, { "Authorization" => "Bearer #{stranger}" },
             "tools/list", nil, session: session)

    assert_response :forbidden
  end

  test "the tool list is still the grant, not an allowlist checked at call time" do
    narrow = call(@tenant, [ "xixo:catalog:read" ], "tools/list").dig("result", "tools").map { |t| t["name"] }
    wide = call(@tenant, ALL, "tools/list").dig("result", "tools").map { |t| t["name"] }

    assert_equal [ "search", "feed" ].sort, narrow.sort
    assert_includes wide, "resource"
    assert_not_includes narrow, "resource"
  end

  test "two scope sets do not share a session" do
    _read_held, read_session = session_for(@tenant, [ "xixo:catalog:read" ])
    wide_held = bearer(@tenant, ALL)

    send_rpc(@tenant, wide_held, "tools/list", nil, session: read_session)

    assert_response :not_found
  end
end
