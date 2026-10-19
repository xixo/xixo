require "test_helper"

class ConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  setup do
    @tenant = Tenant.create!(subdomain: "cable-#{SecureRandom.hex(4)}", name: "Cable")
  end

  test "a socket with no session is refused" do
    assert_reject_connection { connect_as(@tenant) }
  end

  test "an unknown subdomain is refused before any session is read" do
    assert_reject_connection { connect "/cable", headers: { "HOST" => "nobody.xixo.test" } }
  end

  test "a session holding a token for this tenant connects and carries its grant" do
    sign_in(@tenant)

    connect_as(@tenant)

    assert_equal @tenant, connection.tenant
    assert connection.grant.permits?("xixo:catalog:read")
  end

  test "a session holding another tenant's token is refused" do
    other = Tenant.create!(subdomain: "cable-#{SecureRandom.hex(4)}", name: "Elsewhere")
    sign_in(other)

    assert_reject_connection { connect_as(@tenant) }
  end

  test "an expired token is refused rather than carried" do
    sign_in(@tenant, expires_in: -60.seconds)

    assert_reject_connection { connect_as(@tenant) }
  end

  test "token cookies without the session they are bound to are refused" do
    sign_in(@tenant)
    @session = {}

    assert_reject_connection { connect_as(@tenant) }
  end

  test "a session carrying nonsense is refused rather than raising" do
    hold("access_token" => "not-a-jwt", "token_type" => "Bearer")

    assert_reject_connection { connect_as(@tenant) }
  end

  test "the grant is narrowed to the scopes the token actually carries" do
    sign_in(@tenant, scopes: %w[xixo:catalog:read])

    connect_as(@tenant)

    assert connection.grant.permits?("xixo:catalog:read")
    assert_not connection.grant.permits?("xixo:resources:command")
  end

  private

    def connect_as(tenant)
      connect "/cable", headers: { "HOST" => "#{tenant.subdomain}.xixo.test" }, session: @session.to_h
    end

    def sign_in(tenant, scopes: Grant::SCOPES, expires_in: 1.hour)
      token = issuer.mint(
        subdomain: tenant.subdomain, scopes: scopes, expires_in: expires_in,
        audience: "http://#{tenant.subdomain}.xixo.test/mcp"
      )

      hold(
        "access_token" => token,
        "token_type" => "Bearer",
        "expires_in" => expires_in.to_i,
        "obtained_at" => Time.current.to_i
      )
    end

    def cookies
      @cookie_jar ||= ActionCable::Connection::TestCookieJar.new.tap do |jar|
        jar.define_singleton_method(:delete) { |name, *| super(name) }
      end
    end

    def hold(held)
      key = Masks::Rails.config.session_key
      bound = SecureRandom.hex(32)
      @session = { key => bound }

      Masks::Rails::SessionCookies.seal(held, bound).scan(/.{1,#{Masks::Rails::SessionCookies::PIECE}}/o)
        .each_with_index { |piece, index| cookies[index.zero? ? key.to_s : "#{key}-#{index}"] = piece }
    end
end
