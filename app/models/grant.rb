class Grant
  class Denied < StandardError; end

  DESCRIBED = {
    "uris:catalog:read" => "Read your catalog",
    "uris:catalog:write" => "Change your catalog",
    "uris:web:read" => "Search the web",
    "uris:web:keep" => "Keep pages from the web",
    "uris:mcp:call" => "Use the servers you have added",
    "uris:resources:read" => "Read your places",
    "uris:resources:command" => "Act on your places",
    "uris:settings:read" => "Read your settings",
    "uris:settings:write" => "Change your settings",
    "uris:settings:admin" => "Change everyone's settings"
  }.freeze

  NAMESPACE = "uris:".freeze

  SCOPES = DESCRIBED.keys.freeze

  ADMINISTRATIVE = %w[uris:settings:admin].freeze

  SIGN_IN = (SCOPES - ADMINISTRATIVE).freeze

  attr_reader :tenant, :claims

  def initialize(tenant:, claims:, agent: false, speaking_for: nil)
    @tenant = tenant
    @claims = claims
    @agent = agent
    @speaking_for = speaking_for

    verify_tenant!
  end

  def subject
    claims.subject
  end

  def agent?
    @agent
  end

  def speaks_for
    agent? ? @speaking_for : subject
  end

  def scopes
    @scopes ||= claims.scopes & SCOPES
  end

  def expires_at
    claims.expires_at
  end

  def permits?(scope)
    scopes.include?(scope.to_s)
  end

  def permit!(scope)
    raise Denied, "this token does not carry #{scope}" unless permits?(scope)

    true
  end

  def tools
    (Tool.all + proxied).select { |tool| permits?(tool.scope) }
                        .map { |tool| tool.respond_to?(:for) ? tool.for(self) : tool }
  end

  def proxied
    return [] unless permits?(Resource::Mcp::SCOPE)

    Resource.capable_of(:tools).reachable_by(self).flat_map(&:proxied_tools)
  end

  private

    def verify_tenant!
      claimed = claims.tenant.subdomain
      return if claimed.blank?

      expected = issuing_tenant
      return if claimed == expected

      raise Denied, "this token was issued for #{claimed}, not #{expected}"
    end

    def issuing_tenant
      return tenant.subdomain if claims.issuer.blank?

      Masks::Client::Issuer.resolve(claims.issuer).tenant.to_h["subdomain"].presence ||
        raise(Denied, "#{claims.issuer} does not say which tenant it is")
    rescue Masks::Client::Error => e
      raise Denied, "#{claims.issuer} could not be asked which tenant it is: #{e.message}"
    end
end
