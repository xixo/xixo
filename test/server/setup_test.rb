require "test_helper"

class SetupTest < ActionDispatch::IntegrationTest
  SETUP = "{ setup { storage inference client } }".freeze

  setup do
    @tenant = Tenant.create!(subdomain: "setup-#{SecureRandom.hex(4)}", name: "Setup")

    connect!(@tenant)
  end

  test "a new install has nothing in place, and each step turns true as it lands" do
    assert_equal({ "storage" => false, "inference" => false, "client" => false }, asked)

    Tenant.switch(@tenant) do
      Resource::Database.create!(key: "store", name: "Store").make_default_storage!
      Resource::OpenaiCompatible.create!(key: "ollama", details: { "base_url" => "http://ollama.test:11434/v1" })
      AuditEvent.record(channel: "mcp", action: "search", status: "ok", grant: grant_for("ada"))
    end

    assert_equal({ "storage" => true, "inference" => true, "client" => true }, asked)
  end

  test "a model server that fails its check, or an agent's own tool call, does not count" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(key: "ollama", details: { "base_url" => "http://ollama.test:11434/v1" },
                                         checked_at: Time.current, check_error: "connection refused")
      AuditEvent.record(channel: "mcp", action: "search", status: "ok", grant: Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "agent"), agent: true, speaking_for: "ada"))
    end

    assert_equal({ "storage" => false, "inference" => false, "client" => false }, asked)
  end

  private

    def asked
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "ada", scopes: Grant::SCOPES,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: SETUP }, headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body.dig("data", "setup")
    end

    def grant_for(subject)
      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => Grant::SCOPES.join(" ")))
    end
end
