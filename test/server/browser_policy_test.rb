require "test_helper"

class BrowserPolicyTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(subdomain: "policy-#{SecureRandom.hex(4)}", name: "Policy")
    connect!(@tenant)
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
end
