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

  test "GET is a stream now rather than a 405" do
    held, session = session_for(@tenant, ALL)

    get "/mcp", headers: host_for(@tenant).merge(held)
                                          .merge("HTTP_ACCEPT" => "text/event-stream",
                                                 McpTransports::SESSION_HEADER => session)

    assert_response :success
    assert_equal "text/event-stream", response.headers["content-type"]
    assert_equal "no-cache", response.headers["cache-control"]
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
