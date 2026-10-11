module Machines
  def dpop_key
    @dpop_key ||= OpenSSL::PKey::EC.generate("prime256v1")
  end

  def jkt(key = dpop_key)
    Masks::Client::Proof.thumbprint(JWT::JWK.new(key).export.transform_keys(&:to_s))
  end

  def machine_token(tenant, client_id:, scopes: [ Grant::MACHINE ], bound: true, subject: client_id, expires_in: 1.hour)
    issuer.mint(
      subdomain: tenant.subdomain, subject: subject, scopes: scopes, expires_in: expires_in,
      audience: "http://#{tenant.subdomain}.xixo.test/mcp", client_id: client_id,
      cnf: bound ? { "jkt" => jkt } : nil
    )
  end

  def dpop_proof(token, url:, method: "GET", key: dpop_key, iat: Time.current.to_i)
    jwk = JWT::JWK.new(key).export.except(:kid)

    JWT.encode(
      { "htm" => method, "htu" => url, "iat" => iat, "jti" => SecureRandom.uuid,
        "ath" => Masks::Client::Proof.digest(token) },
      key, "ES256", { typ: "dpop+jwt", jwk: jwk }
    )
  end

  def agent_on(tenant, key: "box", client_id: "agent-#{SecureRandom.hex(4)}", folders: [ "/srv/media" ], connected: true)
    Tenant.switch(tenant) do
      Resource::XixoAgent.create!(
        key: key, name: key,
        details: {
          "host" => "100.64.0.9", "user" => "jon", "folders" => folders, "client_id" => client_id,
          "machine" => {
            "hostname" => key, "folders" => folders, "connected" => connected,
            "session" => "s", "seen_at" => Time.current.utc.iso8601
          }
        }
      )
    end
  end
end
