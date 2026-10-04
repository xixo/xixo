require "test_helper"

class GrantTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "grant-#{SecureRandom.hex(4)}", name: "Grants")
  end

  test "the granted scopes are the intersection with the ones this app defines" do
    grant = build(scope: "openid xixo:catalog:read profile xixo:resources:command nonsense")

    assert_equal [ "xixo:catalog:read", "xixo:resources:command" ], grant.scopes
  end

  test "the tool list is the grant, so an ungranted tool is never registered" do
    names = build(scope: "xixo:catalog:read").tools.map(&:tool_name)

    assert_equal %w[search feed], names
    assert_empty build(scope: "openid").tools
  end

  test "a token whose tenant claim names another tenant is refused" do
    error = assert_raises(Grant::Denied) do
      build(scope: "xixo:catalog:read", tenant: { "subdomain" => "somebody-else" })
    end

    assert_match(/issued for somebody-else/, error.message)
  end

  test "a token with a matching tenant claim is accepted" do
    grant = build(scope: "xixo:catalog:read", tenant: { "subdomain" => @tenant.subdomain })

    assert grant.permits?("xixo:catalog:read")
  end

  test "a token carrying no tenant claim is accepted, since the audience already bound it" do
    assert build(scope: "xixo:catalog:read").permits?("xixo:catalog:read")
  end

  test "one fixed issuer names its own tenant, which need not share this tenant's subdomain" do
    issuer = FakeIssuer.current.url_for("masks")

    grant = build(scope: "xixo:catalog:read", tenant: { "subdomain" => "masks" }, issuer: issuer)

    assert grant.permits?("xixo:catalog:read")
  end

  test "a token claiming a tenant other than the one its issuer speaks for is refused" do
    issuer = FakeIssuer.current.url_for("masks")

    error = assert_raises(Grant::Denied) do
      build(scope: "xixo:catalog:read", tenant: { "subdomain" => "acme" }, issuer: issuer)
    end

    assert_match(/issued for acme, not masks/, error.message)
  end

  private

    def build(scope:, tenant: nil, issuer: nil)
      claims = { "sub" => "someone", "scope" => scope, "exp" => 1.hour.from_now.to_i }
      claims["tenant"] = tenant if tenant
      claims["iss"] = issuer if issuer

      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new(claims))
    end
end
