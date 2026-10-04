require "test_helper"

class NotingTest < ActionDispatch::IntegrationTest
  NOTE = <<~GQL.freeze
    mutation($id: ID!, $note: String) {
      noteFeed(input: { id: $id, note: $note }) { feed { id note } }
    }
  GQL

  SEARCH = <<~GQL.freeze
    query($query: String) { search(query: $query) { nodes { title note } } }
  GQL

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "note-#{SecureRandom.hex(4)}", name: "Noting")

    Tenant.switch(@tenant) do
      @item = create_feed(mime: "application/pdf", title: "scan-0042.pdf",
                          locator_key: "inbox/scan-0042.pdf")
    end

    SearchIndex.refresh!
    connect!(@tenant)
  end

  test "a note is searchable in its own right, not only readable on the item" do
    execute(NOTE, variables: { id: @item.id, note: "paid on the fourth, ref 88120" })

    SearchIndex.refresh!

    found = execute(SEARCH, variables: { query: "88120" }).dig("data", "search", "nodes")

    assert_equal [ "scan-0042.pdf" ], found.map { |held| held["title"] }
    assert_equal "paid on the fourth, ref 88120", found.first["note"]
  end

  test "a blank note clears what was there rather than storing whitespace" do
    execute(NOTE, variables: { id: @item.id, note: "something" })
    cleared = execute(NOTE, variables: { id: @item.id, note: "   " })

    assert_nil cleared.dig("data", "noteFeed", "feed", "note")
    Tenant.switch(@tenant) { assert_nil @item.reload.note }
  end

  test "a note longer than the limit is refused" do
    body = execute(NOTE, variables: { id: @item.id, note: "x" * 10_001 })

    assert_nil body.dig("data", "noteFeed")
    assert_match(/longer than 10000/, body.dig("errors", 0, "message"))
  end

  test "noting needs the write scope, not the read one" do
    body = execute(NOTE, scopes: %w[xixo:catalog:read],
                         variables: { id: @item.id, note: "nope" })

    assert_nil body.dig("data", "noteFeed")
    Tenant.switch(@tenant) { assert_nil @item.reload.note }
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
