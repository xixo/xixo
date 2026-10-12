require "test_helper"

class SetupTest < ActionDispatch::IntegrationTest
  SETUP = "{ setup { storage inference client } }".freeze
  HELD = <<~GRAPHQL.freeze
    { setup { inference
      storageResource { id key name kind model down }
      inferenceResource { id key name kind model down }
      connectedClient { name person at } } }
  GRAPHQL

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

  test "each step names what took care of it" do
    Tenant.switch(@tenant) do
      Resource::Database.create!(key: "store", name: "Store").make_default_storage!
      Resource::OpenaiCompatible.create!(key: "ollama", details: { "base_url" => "http://ollama.test:11434/v1",
                                                                   "models" => { "agent" => "gemma3:4b" } })
      AuditEvent.record(channel: "mcp", action: "search", status: "ok",
                        grant: Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "ada", "client_id" => "claude-code", "name" => "Ada")))
    end

    held = asked(HELD)
    ids = Tenant.switch(@tenant) { Resource.where(key: %w[store ollama]).pluck(:key, :id).to_h }

    assert_equal({ "id" => ids["store"].to_s, "key" => "store", "name" => "Store", "kind" => "the catalog's own database",
                   "model" => nil, "down" => false }, held["storageResource"])
    assert_equal({ "id" => ids["ollama"].to_s, "key" => "ollama", "kind" => "a model server", "model" => "gemma3:4b",
                   "down" => false }, held["inferenceResource"].except("name"))
    assert_equal({ "name" => "claude-code", "person" => "Ada" }, held["connectedClient"].except("at"))
  end

  test "a model server that fails its check is still named, as down" do
    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(key: "ollama", details: { "base_url" => "http://ollama.test:11434/v1" },
                                         checked_at: Time.current, check_error: "connection refused")
    end

    held = asked(HELD)

    assert_equal false, held["inference"]
    assert_equal [ "ollama", true, nil ], held["inferenceResource"].values_at("key", "down", "model")
    assert_nil held["storageResource"]
    assert_nil held["connectedClient"]
  end

  private

    def asked(query = SETUP)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "ada", scopes: Grant::SCOPES,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: query }, headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body.dig("data", "setup")
    end

    def grant_for(subject)
      Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => Grant::SCOPES.join(" ")))
    end
end
