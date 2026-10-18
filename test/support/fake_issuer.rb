require "socket"

class FakeIssuer
  ALGORITHM = "RS256".freeze

  class << self
    def current
      @current ||= new
    end

    def template
      "#{current.origin}/%{subdomain}"
    end
  end

  attr_reader :port, :enrollments, :unenrollments

  def initialize
    @keys = {}
    @codes = {}
    @devices = {}
    @approvals = {}
    @enrollments = []
    @unenrollments = []
    @lock = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def origin
    "http://127.0.0.1:#{port}"
  end

  def url_for(subdomain)
    "#{origin}/#{subdomain}"
  end

  def authorize!(location, scopes: Grant::SCOPES)
    query = Rack::Utils.parse_query(URI.parse(location).query)
    code = SecureRandom.urlsafe_base64(24)

    @lock.synchronize do
      @codes[code] = {
        challenge: query["code_challenge"],
        nonce: query["nonce"],
        client_id: query["client_id"],
        resource: query["resource"],
        scopes: Array(scopes)
      }
    end

    { code: code, state: query["state"], query: query }
  end

  def approve_device!(user_code, scopes: Grant::SCOPES, subject: "owner")
    @lock.synchronize do
      held = @devices.values.find { |device| device[:user_code] == user_code }
      held[:approved] = { scopes: Array(scopes), subject: subject } if held
      !held.nil?
    end
  end

  def approve!(subdomain)
    secret = SecureRandom.urlsafe_base64(24)

    @lock.synchronize { @approvals[secret] = subdomain }
    secret
  end

  def key_for(subdomain)
    @lock.synchronize do
      @keys[subdomain] ||= { key: OpenSSL::PKey::RSA.generate(2048), kid: SecureRandom.uuid }
    end
  end

  def mint(subdomain:, subject: "test", scopes: [], audience:, expires_in: 1.hour,
           tenant: nil, typ: "at+jwt", **extra)
    held = key_for(subdomain)

    JWT.encode({
      "iss" => url_for(subdomain),
      "sub" => subject,
      "aud" => audience,
      "exp" => expires_in.from_now.to_i,
      "iat" => Time.current.to_i,
      "jti" => SecureRandom.uuid,
      "scope" => Array(scopes).join(" "),
      "tenant" => tenant || { "uuid" => SecureRandom.uuid, "subdomain" => subdomain }
    }.merge(extra).compact, held[:key], ALGORITHM, { kid: held[:kid], typ: typ })
  end

  private

    def serve
      loop do
        socket = @server.accept
        Thread.new { respond(socket) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def respond(socket)
      line = socket.gets.to_s
      length = 0
      bearer = nil
      basic = nil

      while (header = socket.gets) && header.strip != ""
        length = header.split(":", 2).last.to_i if header =~ /\AContent-Length:/i
        bearer = header.split(" ").last.strip if header =~ /\AAuthorization:\s*Bearer /i
        basic = header.split(" ").last.strip if header =~ /\AAuthorization:\s*Basic /i
      end

      method, path = line.split(" ")
      payload = length.positive? ? socket.read(length).to_s : ""

      found = if method == "POST" && path.to_s =~ %r{\A/([^/]+)/enrollments\z}
        enrolled($1, payload, basic)
      elsif method == "DELETE" && path.to_s =~ %r{\A/([^/]+)/enrollments/([^/]+)\z}
        unenrolled($1, $2, basic)
      else
        method == "POST" ? post_for(path.to_s, payload, bearer) : body_for(path.to_s)
      end
      body = JSON.generate(found || { "error" => "not_found" })

      status = if found.nil?
        "404 Not Found"
      elsif found["error"]
        "400 Bad Request"
      else
        "200 OK"
      end

      socket.print [
        "HTTP/1.1 #{status}",
        "Content-Type: application/json",
        "Content-Length: #{body.bytesize}",
        "Connection: close",
        "", body
      ].join("\r\n")
    rescue Errno::EPIPE, IOError
      nil
    ensure
      socket.close rescue nil
    end

    def body_for(path)
      case path
      when %r{\A/([^/]+)/\.well-known/openid-configuration\z} then discovery($1)
      when %r{\A/([^/]+)/\.well-known/jwks\.json\z} then jwks($1)
      when %r{\A/([^/]+)/register/([^/]+)\z}
        { "client_id" => $2, "registration_client_uri" => "#{url_for($1)}/register/#{$2}" }
      end
    end

    def post_for(path, payload, token)
      return registered($1, payload, token) if path =~ %r{\A/([^/]+)/register\z}
      return device_started($1, payload) if path =~ %r{\A/([^/]+)/device_authorization\z}
      return nil unless path =~ %r{\A/([^/]+)/token\z}

      subdomain = $1
      form = URI.decode_www_form(payload).to_h
      return device_polled(subdomain, form) if form["grant_type"] == Masks::Client::Device::GRANT_TYPE
      return refreshed(subdomain, form) if form["grant_type"] == "refresh_token"

      pending = @lock.synchronize { @codes.delete(form["code"]) }

      return { "error" => "invalid_grant" } if pending.nil?
      return { "error" => "invalid_grant" } unless verifies?(pending, form["code_verifier"])

      granted(subdomain, pending)
    end

    def verifies?(pending, verifier)
      return false if verifier.blank?

      Base64.urlsafe_encode64(
        OpenSSL::Digest::SHA256.digest(verifier), padding: false
      ) == pending[:challenge]
    end

    def granted(subdomain, pending)
      audience = pending[:resource].presence || "#{url_for(subdomain)}/mcp"

      {
        "access_token" => mint(subdomain: subdomain, scopes: pending[:scopes], audience: audience),
        "id_token" => mint(subdomain: subdomain, audience: pending[:client_id], typ: "JWT",
                           scopes: [], nonce: pending[:nonce],
                           name: "Test Owner", preferred_username: "owner",
                           email: "owner@example.invalid"),
        "refresh_token" => SecureRandom.urlsafe_base64(24),
        "token_type" => "Bearer",
        "scope" => Array(pending[:scopes]).join(" "),
        "expires_in" => 3600
      }
    end

    def device_started(subdomain, payload)
      form = URI.decode_www_form(payload).to_h
      device_code = SecureRandom.urlsafe_base64(24)
      user_code = "#{SecureRandom.alphanumeric(4).upcase}-#{SecureRandom.alphanumeric(4).upcase}"

      @lock.synchronize do
        @devices[device_code] = { user_code: user_code, client_id: form["client_id"], resource: form["resource"],
                                  scopes: form["scope"].to_s.split, approved: nil }
      end

      { "device_code" => device_code, "user_code" => user_code, "verification_uri" => "#{url_for(subdomain)}/device",
        "verification_uri_complete" => "#{url_for(subdomain)}/device?user_code=#{user_code}", "expires_in" => 600, "interval" => 1 }
    end

    def device_polled(subdomain, form)
      held = @lock.synchronize { @devices[form["device_code"]] }
      return { "error" => "invalid_grant", "error_description" => "no such device code" } if held.nil?
      return { "error" => "authorization_pending", "error_description" => "waiting" } if held[:approved].nil?

      @lock.synchronize { @devices.delete(form["device_code"]) }
      audience = held[:resource].presence || "#{url_for(subdomain)}/mcp"

      {
        "access_token" => mint(subdomain: subdomain, subject: held[:approved][:subject], scopes: held[:approved][:scopes], audience: audience),
        "refresh_token" => "refresh-#{SecureRandom.hex(8)}",
        "token_type" => "Bearer", "scope" => held[:approved][:scopes].join(" "), "expires_in" => 3600
      }
    end

    def refreshed(subdomain, form)
      return { "error" => "invalid_grant", "error_description" => "that refresh token is not one this issuer gave out" } unless form["refresh_token"].to_s.start_with?("refresh-")

      audience = form["resource"].presence || "#{url_for(subdomain)}/mcp"

      { "access_token" => mint(subdomain: subdomain, subject: "owner", scopes: Grant::SCOPES, audience: audience),
        "refresh_token" => "refresh-#{SecureRandom.hex(8)}", "token_type" => "Bearer",
        "scope" => Grant::SCOPES.join(" "), "expires_in" => 3600 }
    end

    def registered(subdomain, payload, token)
      approved = @lock.synchronize { @approvals.delete(token) }

      return { "error" => "invalid_token" } unless approved == subdomain

      metadata = JSON.parse(payload) rescue {}
      client_id = SecureRandom.uuid

      metadata.merge(
        "client_id" => client_id,
        "client_secret" => SecureRandom.urlsafe_base64(24),
        "registration_access_token" => SecureRandom.urlsafe_base64(24),
        "registration_client_uri" => "#{url_for(subdomain)}/register/#{client_id}"
      )
    end

    def enrolled(subdomain, payload, basic)
      client_id, secret = Base64.decode64(basic.to_s).split(":", 2).map { |part| URI.decode_www_form_component(part) }
      return { "error" => "invalid_client" } if client_id.blank? || secret.blank?

      form = URI.decode_www_form(payload).to_h
      @lock.synchronize { @enrollments << form.merge("subdomain" => subdomain, "client_id" => client_id) }

      { "initial_access_token" => "enroll-#{SecureRandom.hex(8)}", "expires_in" => form["expires_in"].to_i, "scope" => form["scope"] }
    end

    def unenrolled(subdomain, machine, basic)
      client_id, secret = Base64.decode64(basic.to_s).split(":", 2).map { |part| URI.decode_www_form_component(part) }
      return { "error" => "invalid_client" } if client_id.blank? || secret.blank?

      @lock.synchronize { @unenrollments << { "subdomain" => subdomain, "client_id" => client_id, "machine" => machine } }

      {}
    end

    def discovery(subdomain)
      url = url_for(subdomain)

      {
        "issuer" => url,
        "authorization_endpoint" => "#{url}/authorize",
        "token_endpoint" => "#{url}/token",
        "device_authorization_endpoint" => "#{url}/device_authorization",
        "userinfo_endpoint" => "#{url}/userinfo",
        "jwks_uri" => "#{url}/.well-known/jwks.json",
        "registration_endpoint" => "#{url}/register",
        "handshake_endpoint" => "#{url}/handshake",
        "revocation_endpoint" => "#{url}/revoke",
        "tenant" => { "subdomain" => subdomain }
      }
    end

    def jwks(subdomain)
      held = key_for(subdomain)

      { "keys" => [ JWT::JWK.new(held[:key], { kid: held[:kid], use: "sig", alg: ALGORITHM }).export ] }
    end
end
