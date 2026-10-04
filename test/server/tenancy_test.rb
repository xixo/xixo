require "test_helper"

class TenancyTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(subdomain: "demo", name: "Demo items")

    Tenant.switch(@tenant) { Feed.create!(type: Feed::FILE, key: "Demo invoice", title: "Demo invoice") }
  end

  test "a hostname that serves no tenant is refused before the request reaches a controller" do
    get "http://nobody.xixo.test/"

    assert_response :not_found
    assert_equal Tenancy::Middleware::UNSERVED, response.body
  end

  test "the health check answers on a hostname that serves no tenant" do
    get "http://localhost/up"

    assert_response :success
  end

  test "a request leaves no tenant behind on the connection it borrowed" do
    get "http://demo.xixo.test/"

    assert_equal 0, Feed.unscoped.count,
                 "the request left its tenant on the connection, and the next request to " \
                 "borrow it would read this tenant's rows before resolving its own"
  end

  test "a request holds no transaction open for its life" do
    depth = ActiveRecord::Base.connection.open_transactions

    get "http://demo.xixo.test/"

    assert_equal depth, ActiveRecord::Base.connection.open_transactions
  end
end
