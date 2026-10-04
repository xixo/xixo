require "test_helper"

class UpdatingTest < ActionDispatch::IntegrationTest
  UPDATE = <<~GQL.freeze
    mutation($id: ID!, $name: String, $settings: JSON) {
      updateResource(input: { id: $id, name: $name, settings: $settings }) {
        resource { id key name settings heldCredentials }
        checkError
      }
    }
  GQL

  READ = <<~GQL.freeze
    { resources { id key settings heldCredentials changeable } }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "update-#{SecureRandom.hex(4)}", name: "Updating")
    connect!(@tenant)

    Tenant.switch(@tenant) do
      @server = Resource::Mcp.create!(
        key: "exa", name: "Exa",
        details: { "url" => "https://mcp.example.test/mcp", "auth" => "basic",
                   "tools" => [ { "name" => "web_search" } ] },
        credentials: { "username" => "reader", "password" => "first-password" }
      )
    end
  end

  test "a resource reads back what its form holds in the clear, and only the names of what is encrypted" do
    held = execute(READ).dig("data", "resources").find { |resource| resource["key"] == "exa" }

    assert_equal({ "url" => "https://mcp.example.test/mcp", "auth" => "basic" }, held["settings"])
    assert_equal %w[username password], held["heldCredentials"]
    assert held["changeable"]
    assert_not_includes response.body, "first-password"
    assert_not_includes response.body, "reader"
  end

  test "a change is saved and checked, and a secret left empty keeps what it held" do
    body = execute(UPDATE, variables: {
      id: @server.id, name: "Exa search",
      settings: { "url" => "https://mcp.example.test/v2/mcp", "auth" => "basic", "username" => "writer", "password" => "" }
    })

    assert_predicate body.dig("data", "updateResource", "checkError"), :present?

    Tenant.switch(@tenant) do
      @server.reload

      assert_equal "Exa search", @server.name
      assert_equal "https://mcp.example.test/v2/mcp", @server.details["url"]
      assert_equal({ "username" => "writer", "password" => "first-password" }, @server.credentials)
      assert_predicate @server.checked_at, :present?
    end
  end

  test "changing how it authenticates drops the credentials the old way sent" do
    execute(UPDATE, variables: {
      id: @server.id,
      settings: { "url" => "https://mcp.example.test/mcp", "auth" => "header", "header_name" => "X-API-Key", "header_value" => "key-1" }
    })

    Tenant.switch(@tenant) do
      assert_equal({ "header_value" => "key-1" }, @server.reload.credentials)
    end
  end

  test "a secret the new way needs and nothing holds is refused by name" do
    body = execute(UPDATE, variables: {
      id: @server.id, settings: { "url" => "https://mcp.example.test/mcp", "auth" => "bearer" }
    })

    assert_match(/Bearer token is needed/, body.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert_equal "basic", @server.reload.details["auth"] }
  end

  test "what the resource keeps for itself beside its form survives a change" do
    execute(UPDATE, variables: {
      id: @server.id, settings: { "url" => "https://mcp.example.test/mcp", "auth" => "basic", "username" => "reader" }
    })

    Tenant.switch(@tenant) do
      assert_equal [ { "name" => "web_search" } ], @server.reload.details["tools"]
    end
  end

  test "a name alone can change without touching the settings" do
    execute(UPDATE, variables: { id: @server.id, name: "Renamed" })

    Tenant.switch(@tenant) do
      @server.reload

      assert_equal "Renamed", @server.name
      assert_equal "first-password", @server.credentials["password"]
    end
  end

  test "a store xixo keeps for itself cannot be changed, and neither can one in another tenant" do
    internal = Tenant.switch(@tenant) { Resource.internal!(:children) }
    other = Tenant.create!(subdomain: "update-#{SecureRandom.hex(4)}", name: "Elsewhere")
    theirs = Tenant.switch(other) { Resource::Curl.create!(key: "curl", name: "Theirs") }

    [ internal, theirs ].each do |resource|
      body = execute(UPDATE, variables: { id: resource.id, name: "Mine now" })

      assert_match(/no resource with id/, body.dig("errors", 0, "message"))
    end
  end

  test "changing needs the command scope" do
    body = execute(UPDATE, scopes: %w[xixo:resources:read], variables: { id: @server.id, name: "Nope" })

    assert_nil body.dig("data", "updateResource")
    Tenant.switch(@tenant) { assert_equal "Exa", @server.reload.name }
  end

  test "a change is audited by the names of what was set, never their values" do
    execute(UPDATE, variables: {
      id: @server.id, settings: { "url" => "https://mcp.example.test/mcp", "auth" => "basic", "username" => "writer", "password" => "second" }
    })

    Tenant.switch(@tenant) do
      event = AuditEvent.find_by!(action: "update_resource")

      assert_equal "url, auth, username, password", event.arguments["set"]
      assert_not_includes event.arguments.to_json, "second"
    end
  end

  private

    def host_for(tenant)
      { "HOST" => "#{tenant.subdomain}.xixo.test" }
    end

    def bearer(tenant, scopes: Grant::SCOPES)
      token = issuer.mint(
        subdomain: tenant.subdomain, scopes: scopes,
        audience: "http://#{tenant.subdomain}.xixo.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end

    def execute(query, variables: nil, scopes: Grant::SCOPES)
      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: host_for(@tenant).merge(bearer(@tenant, scopes: scopes))

      response.parsed_body
    end
end
