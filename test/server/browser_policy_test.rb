require "test_helper"

class BrowserPolicyTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(subdomain: "policy-#{SecureRandom.hex(4)}", name: "Policy")
    connect!(@tenant)
  end

  test "the app runs only its own script, and no other site may frame it" do
    get "/", headers: host

    assert_response :success

    policy = directives(response.headers["Content-Security-Policy"])

    assert_equal %w['self'], policy["default-src"]
    assert_equal %w['none'], policy["object-src"]
    assert_equal %w['none'], policy["base-uri"]
    assert_equal %w['none'], policy["frame-ancestors"]
    assert_equal %w['self'], policy["connect-src"]
    assert_equal "'self'", policy["script-src"].first
    assert_match(/\A'nonce-[A-Za-z0-9+\/=]+'\z/, policy["script-src"].second)
    assert_not_includes policy["script-src"], "'unsafe-inline'"
  end

  test "pictures load from this app and from the issuer that draws avatars" do
    get "/", headers: host

    sources = directives(response.headers["Content-Security-Policy"])["img-src"]

    assert_includes sources, "'self'"
    assert_includes sources, Masks::Client::Nonces.origin(issuer.url_for(@tenant.subdomain))
  end

  test "each page gets a script nonce of its own" do
    nonces = 2.times.map do
      get "/", headers: host

      directives(response.headers["Content-Security-Policy"])["script-src"].second
    end

    assert_equal 2, nonces.uniq.size
  end

  test "the session cookie stays home when another site starts the request" do
    get "/auth", headers: host

    cookie = Array(response.headers["Set-Cookie"]).flat_map { |line| line.split("\n") }.find { |line| line.start_with?("_xixo_session=") }

    assert cookie, "the sign-in start sets a session cookie"
    assert_match(/;\s*samesite=lax/i, cookie)
    assert_match(/;\s*httponly/i, cookie)
  end

  private

    def host
      { "HOST" => "#{@tenant.subdomain}.xixo.test" }
    end

    def directives(header)
      header.to_s.split(";").map(&:split).reject(&:empty?).to_h { |name, *sources| [ name, sources ] }
    end
end
