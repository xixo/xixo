require "test_helper"

class FirstAdministratorTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(subdomain: "first-#{SecureRandom.hex(4)}", name: "First")
    connect!(@tenant)
  end

  test "until someone administers xixo, a sign-in asks masks for the administrator scope" do
    assert_includes asked, "xixo:settings:admin"
  end

  test "once someone has administered xixo, a sign-in asks only for the usual scopes" do
    @tenant.administered!

    assert_not_includes asked, "xixo:settings:admin"
    assert_includes asked, "xixo:catalog:read"
  end

  test "a sign-in that names its privilege keeps it" do
    @tenant.administered!

    assert_includes asked(privilege: "admin"), "xixo:settings:admin"
  end

  test "disconnecting from masks forgets who administered xixo" do
    @tenant.administered!
    @tenant.disconnect!

    assert_not @tenant.reload.administered?
  end

  private

    def asked(**params)
      get "/auth", params: params, headers: { "HOST" => "#{@tenant.subdomain}.xixo.test" }

      assert_response :redirect
      Rack::Utils.parse_query(URI.parse(response.location).query)["scope"].split
    end
end
