require "socket"
require "json"
require "securerandom"
require "digest"
require "base64"
require "uri"

class McpOauthServer
  Request = Struct.new(:verb, :path, :query, :headers, :body) do
    def form
      URI.decode_www_form(body.to_s).to_h
    end

    def json
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end

    def bearer
      headers["authorization"].to_s[/\ABearer (.+)\z/, 1]
    end

    def basic
      encoded = headers["authorization"].to_s[/\ABasic (.+)\z/, 1]
      encoded && Base64.decode64(encoded).split(":", 2)
    end
  end

  def initialize(origin:, browser:, port:, lifetime:, subject:)
    @origin = origin.chomp("/")
    @browser = browser.chomp("/")
    @port = port
    @lifetime = lifetime
    @subject = subject
    @clients = {}
    @codes = {}
    @access = {}
    @refresh = {}
    @lock = Mutex.new
  end

  def run
    server = TCPServer.new("::", @port)
    log "listening on #{@port}, advertised as #{@origin}, tokens live #{@lifetime}s, signing in #{@subject}"

    loop do
      socket = server.accept
      Thread.new(socket) { |held| serve(held) }
    end
  end

  private

    def serve(socket)
      request = read(socket)
      return socket.close if request.nil?

      status, headers, body = @lock.synchronize { route(request) }
      log "#{request.verb} #{request.path} -> #{status}"
      write(socket, status, headers, body)
    rescue StandardError => e
      log "error: #{e.class}: #{e.message}"
      write(socket, 500, {}, { error: "server_error" }.to_json)
    ensure
      socket.close unless socket.closed?
    end

    def route(request)
      case [ request.verb, request.path ]
      in [ "GET", "/.well-known/oauth-protected-resource" | "/.well-known/oauth-protected-resource/mcp" ]
        json(200, resource: "#{@origin}/mcp", authorization_servers: [ @origin ], bearer_methods_supported: [ "header" ])
      in [ "GET", "/.well-known/oauth-authorization-server" ]
        json(200, metadata)
      in [ "POST", "/register" ]
        register(request)
      in [ "GET", "/authorize" ]
        authorize(request)
      in [ "POST", "/token" ]
        token(request)
      in [ "POST", "/mcp" ]
        mcp(request)
      in [ "DELETE", "/mcp" ]
        [ 204, {}, "" ]
      else
        json(404, error: "not_found")
      end
    end

    def metadata
      {
        issuer: @origin,
        authorization_endpoint: "#{@browser}/authorize",
        token_endpoint: "#{@origin}/token",
        registration_endpoint: "#{@origin}/register",
        response_types_supported: [ "code" ],
        grant_types_supported: %w[authorization_code refresh_token],
        code_challenge_methods_supported: [ "S256" ],
        token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post none]
      }
    end

    def register(request)
      asked = request.json
      uris = Array(asked["redirect_uris"])
      return json(400, error: "invalid_redirect_uri") if uris.empty?

      method = asked["token_endpoint_auth_method"] || "client_secret_basic"
      client = { "client_id" => "mcp-#{SecureRandom.hex(8)}", "redirect_uris" => uris,
                 "token_endpoint_auth_method" => method }
      client["client_secret"] = SecureRandom.hex(24) unless method == "none"
      @clients[client["client_id"]] = client

      json(201, client.merge("client_id_issued_at" => Time.now.to_i))
    end

    def authorize(request)
      asked = request.query
      client = @clients[asked["client_id"]]

      return json(400, error: "invalid_client") if client.nil?
      return json(400, error: "invalid_redirect_uri") unless client["redirect_uris"].include?(asked["redirect_uri"])
      return json(400, error: "invalid_request", error_description: "S256 PKCE is required") unless asked["code_challenge_method"] == "S256"

      code = SecureRandom.hex(16)
      @codes[code] = { "client_id" => client["client_id"], "redirect_uri" => asked["redirect_uri"],
                       "challenge" => asked["code_challenge"], "resource" => asked["resource"] }

      target = URI(asked["redirect_uri"])
      target.query = URI.encode_www_form([ *URI.decode_www_form(target.query.to_s), [ "code", code ], [ "state", asked["state"] ] ].compact)

      [ 302, { "Location" => target.to_s }, "" ]
    end

    def token(request)
      given = request.form
      client = authenticated(request, given)
      return json(401, error: "invalid_client") if client.nil?

      case given["grant_type"]
      when "authorization_code" then by_code(client, given)
      when "refresh_token" then by_refresh(client, given)
      else json(400, error: "unsupported_grant_type")
      end
    end

    def authenticated(request, given)
      id, secret = request.basic || [ given["client_id"], given["client_secret"] ]
      client = @clients[id]
      return nil if client.nil?
      return client if client["token_endpoint_auth_method"] == "none"

      client if secret.to_s != "" && secret == client["client_secret"]
    end

    def by_code(client, given)
      held = @codes.delete(given["code"])
      return json(400, error: "invalid_grant") if held.nil? || held["client_id"] != client["client_id"]

      verified = Base64.urlsafe_encode64(Digest::SHA256.digest(given["code_verifier"].to_s), padding: false)
      return json(400, error: "invalid_grant", error_description: "PKCE verifier") unless verified == held["challenge"]

      issued(client)
    end

    def by_refresh(client, given)
      held = @refresh.delete(given["refresh_token"])
      return json(400, error: "invalid_grant") if held.nil? || held != client["client_id"]

      issued(client)
    end

    def issued(client)
      access = SecureRandom.hex(20)
      refresh = SecureRandom.hex(20)
      @access[access] = { "subject" => @subject, "expires_at" => Time.now.to_i + @lifetime }
      @refresh[refresh] = client["client_id"]

      json(200, access_token: access, token_type: "Bearer", expires_in: @lifetime, refresh_token: refresh)
    end

    def mcp(request)
      held = @access[request.bearer.to_s]

      if held.nil? || held["expires_at"] <= Time.now.to_i
        return [ 401, { "WWW-Authenticate" => %(Bearer resource_metadata="#{@origin}/.well-known/oauth-protected-resource"),
                        "Content-Type" => "application/json" }, { error: "invalid_token" }.to_json ]
      end

      asked = request.json
      return [ 202, {}, "" ] if asked["id"].nil?

      json(200, jsonrpc: "2.0", id: asked["id"], result: answer(asked, held))
    end

    def answer(asked, held)
      case asked["method"]
      when "initialize"
        { protocolVersion: asked.dig("params", "protocolVersion") || "2025-06-18",
          capabilities: { tools: {} }, serverInfo: { name: "mcp-oauth-server", version: "1" } }
      when "tools/list"
        { tools: [ { name: "whoami", description: "Says whose token called it.",
                     inputSchema: { type: "object", properties: {} }, annotations: { readOnlyHint: true } } ] }
      when "tools/call"
        { content: [ { type: "text", text: "called by #{held['subject']}" } ], isError: false }
      else
        {}
      end
    end

    def json(status, body)
      [ status, { "Content-Type" => "application/json" }, body.to_json ]
    end

    def read(socket)
      line = socket.gets
      return nil if line.nil?

      verb, target = line.split(" ", 3)
      headers = {}
      while (header = socket.gets) && header != "\r\n"
        name, value = header.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end

      body = socket.read(headers["content-length"].to_i) if headers["content-length"].to_i.positive?
      uri = URI(target.to_s)

      Request.new(verb, uri.path, URI.decode_www_form(uri.query.to_s).to_h, headers, body)
    end

    def write(socket, status, headers, body)
      reason = { 200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content", 302 => "Found",
                 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 500 => "Internal Server Error" }
      socket.write("HTTP/1.1 #{status} #{reason.fetch(status, 'OK')}\r\n")
      headers.merge("Content-Length" => body.bytesize, "Connection" => "close").each { |name, value| socket.write("#{name}: #{value}\r\n") }
      socket.write("\r\n#{body}")
    end

    def log(message)
      warn "[mcp-oauth] #{message}"
    end
end

if $PROGRAM_NAME == __FILE__
  origin = ENV.fetch("MCP_OAUTH_ORIGIN", "http://mcp.localhost:8190")

  McpOauthServer.new(
    origin: origin,
    browser: ENV.fetch("MCP_OAUTH_BROWSER_ORIGIN", origin),
    port: ENV.fetch("MCP_OAUTH_PORT", "8190").to_i,
    lifetime: ENV.fetch("MCP_OAUTH_LIFETIME", "120").to_i,
    subject: ENV.fetch("MCP_OAUTH_SUBJECT", "ada")
  ).run
end
