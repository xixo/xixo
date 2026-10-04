module McpClient
  PROTOCOL = "2025-06-18".freeze

  def origin_for(tenant)
    "http://#{tenant.subdomain}.xixo.test"
  end

  def host_for(tenant)
    { "HOST" => "#{tenant.subdomain}.xixo.test",
      "HTTP_ACCEPT" => "application/json, text/event-stream" }
  end

  def bearer(tenant, scopes)
    token = issuer.mint(
      subdomain: tenant.subdomain, scopes: scopes,
      audience: "#{origin_for(tenant)}/mcp"
    )

    { "Authorization" => "Bearer #{token}" }
  end

  def rpc(method, params = nil)
    { jsonrpc: "2.0", id: SecureRandom.uuid, method: method, params: params }.compact
  end

  def send_rpc(tenant, held, method, params = nil, session: nil)
    headers = host_for(tenant).merge(held)
    headers[McpTransports::SESSION_HEADER] = session if session

    post "/mcp", headers: headers, params: rpc(method, params), as: :json

    response
  end

  def initialize_session(tenant, scopes, held = bearer(tenant, scopes))
    send_rpc(tenant, held, "initialize",
             { protocolVersion: PROTOCOL, capabilities: {},
               clientInfo: { name: "test", version: "1" } })

    assert_response :success
    response.headers[McpTransports::SESSION_HEADER]
  end

  def session_for(tenant, scopes)
    @mcp_sessions ||= {}
    @mcp_sessions[[ tenant.id, scopes.sort ]] ||= begin
      held = bearer(tenant, scopes)
      [ held, initialize_session(tenant, scopes, held) ]
    end
  end

  def call(tenant, scopes, method, **params)
    held, session = session_for(tenant, scopes)

    send_rpc(tenant, held, method, params.presence, session: session)

    assert_response :success
    response.parsed_body
  end

  def tool(tenant, scopes, name, **arguments)
    reply = call(tenant, scopes, "tools/call", name: name, arguments: arguments)

    assert_not reply.dig("result", "isError"), reply.dig("result", "content", 0, "text")

    JSON.parse(reply.dig("result", "content", 0, "text"))
  end
end
