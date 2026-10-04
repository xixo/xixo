require "test_helper"

class RenamingTest < ActionDispatch::IntegrationTest
  RENAME = <<~GQL.freeze
    mutation($id: ID!, $title: String!) {
      renameFeed(input: { id: $id, title: $title }) { feed { id title } }
    }
  GQL

  SEARCH = <<~GQL.freeze
    query($query: String) { search(query: $query) { total nodes { title } } }
  GQL

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "name-#{SecureRandom.hex(4)}", name: "Renaming")

    Tenant.switch(@tenant) do
      @item = create_feed(mime: "application/pdf", title: "scan-0042.pdf",
                          locator_key: "inbox/scan-0042.pdf")
    end

    SearchIndex.refresh!
    connect!(@tenant)
  end

  test "renaming an item is what a later search finds it by" do
    execute(RENAME, variables: { id: @item.id, title: "March invoice" })

    SearchIndex.refresh!

    found = execute(SEARCH, variables: { query: "invoice" })

    assert_equal [ "March invoice" ], found.dig("data", "search", "nodes").map { |h| h["title"] }
    assert_equal 1, found.dig("data", "search", "total")
  end

  test "a name is trimmed, and a blank one is refused rather than quietly clearing it" do
    kept = execute(RENAME, variables: { id: @item.id, title: "  Padded  " })

    assert_equal "Padded", kept.dig("data", "renameFeed", "feed", "title")

    blank = execute(RENAME, variables: { id: @item.id, title: "   " })

    assert_nil blank.dig("data", "renameFeed")
    assert_match(/needs something to be called/, blank.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert_equal "Padded", @item.reload.title }
  end

  test "a name longer than the limit is refused" do
    body = execute(RENAME, variables: { id: @item.id, title: "x" * 201 })

    assert_nil body.dig("data", "renameFeed")
    assert_match(/longer than 200/, body.dig("errors", 0, "message"))
  end

  test "renaming needs the write scope, not the read one" do
    body = execute(RENAME, scopes: %w[xixo:catalog:read],
                           variables: { id: @item.id, title: "Nope" })

    assert_nil body.dig("data", "renameFeed")
    Tenant.switch(@tenant) { assert_equal "scan-0042.pdf", @item.reload.title }
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
