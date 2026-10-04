require "test_helper"

class TenantOriginTest < ActiveSupport::TestCase
  def request_for(host, base: nil)
    ActionDispatch::Request.new(
      "HTTP_HOST" => host,
      "rack.url_scheme" => "http",
      "SERVER_NAME" => host.split(":").first,
      "SERVER_PORT" => host.split(":").last.to_i.nonzero? || 80
    ).tap { |request| request.define_singleton_method(:base_url) { base } if base }
  end

  def with_origin(value)
    held = ENV["XIXO_PUBLIC_ORIGIN"]
    ENV["XIXO_PUBLIC_ORIGIN"] = value
    yield
  ensure
    ENV["XIXO_PUBLIC_ORIGIN"] = held
  end

  test "with no override the origin is whatever answered the request" do
    with_origin(nil) do
      assert_equal "http://demo.xixo.test", Tenant.origin(request_for("demo.xixo.test"))
    end
  end

  test "an override without a placeholder is used as it stands" do
    with_origin("https://tunnel.example") do
      assert_equal "https://tunnel.example", Tenant.origin(request_for("demo.xixo.test"))
    end
  end

  test "an override takes the subdomain, so each tenant names its own origin" do
    with_origin("http://%{subdomain}.items.localhost:8080") do
      assert_equal "http://demo.items.localhost:8080",
                   Tenant.origin(request_for("demo.items.localhost:8080"))
      assert_equal "http://acme.items.localhost:8080",
                   Tenant.origin(request_for("acme.items.localhost:8080"))
    end
  end

  test "the resource a tenant registers is its own" do
    with_origin("http://%{subdomain}.items.localhost:8080") do
      assert_equal "http://acme.items.localhost:8080/mcp",
                   Tenant.resource_url(request_for("acme.items.localhost:8080"))
    end
  end
end
