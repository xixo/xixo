require "test_helper"

class SearchWebTest < ActionDispatch::IntegrationTest
  include McpClient

  ALL = Grant::SCOPES
  ANSWER = { results: [ { title: "A page", url: "https://example.test/a", text: "what it says" } ] }.freeze

  setup do
    SearchIndex.reset!
    Rails.cache.clear

    @tenant = Tenant.create!(subdomain: "web-#{SecureRandom.hex(4)}", name: "Searcher")
  end

  def attach_engine
    Tenant.switch(@tenant) do
      Resource::Search.create!(key: "exa", name: "Exa", details: { "provider" => "exa" },
                               credentials: { "api_key" => "sk-test" })
    end
  end

  def stub_exa(body = ANSWER)
    stub_request(:post, "https://api.exa.ai/search")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  test "the web is searched through the tenant's own engine" do
    attach_engine
    stub_exa

    found = tool(@tenant, ALL, "resource", key: "exa", do: "search",
                 input: { query: "anything" })

    assert_equal 1, found["count"]
    assert_equal "https://example.test/a", found.dig("results", 0, "url")
  end

  test "a tenant with nothing to search with is told so rather than answering emptily" do
    reply = call(@tenant, ALL, "tools/call", name: "resource",
                 arguments: { key: "exa", do: "search", input: { query: "anything" } })

    assert reply.dig("result", "isError")
    assert_match(/no resource called exa/, reply.dig("result", "content", 0, "text"))
  end

  test "a token without the web scope reaches the tool but not a search engine" do
    attach_engine
    stub_exa

    reply = call(@tenant, Grant::SCOPES - [ "xixo:web:read" ], "tools/call",
                 arguments: { key: "exa", do: "search", input: { query: "anything" } },
                 name: "resource")

    assert reply.dig("result", "isError")
    assert_match(/xixo:web:read/, reply.dig("result", "content", 0, "text"))
  end

  test "the web scope still gates a search-capable resource, though the tool is one of four" do
    attach_engine

    granted = ->(scopes) {
      Grant.new(tenant: @tenant,
                claims: Masks::Client::Claims.new("sub" => "t", "scope" => scopes.join(" ")))
        .tools.map(&:tool_name)
    }

    assert_includes granted.call(ALL), "resource"
    assert_not_includes granted.call([ "xixo:catalog:read" ]), "resource"
  end

  test "an agent is offered the places alongside the catalog" do
    assert_includes Agent::READ_TOOLS, "resource"
  end
end
