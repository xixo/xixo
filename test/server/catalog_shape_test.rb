require "test_helper"

class CatalogShapeTest < ActionDispatch::IntegrationTest
  FEEDS = <<~GQL.freeze
    query($types: [String!], $topLevel: Boolean) {
      feeds(types: $types, topLevel: $topLevel) { nodes { title type } }
    }
  GQL

  TYPES = "{ types { type count } }".freeze

  FEED = <<~GQL.freeze
    query($id: ID) {
      feed(id: $id) { staged children { title } parent { title } analyses { cause } }
    }
  GQL

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "shape-#{SecureRandom.hex(4)}", name: "Shape")

    Tenant.switch(@tenant) do
      @message = Feed.create!(type: Feed::FILE, key: "march.eml", title: "march.eml")
      @attachment = Feed.create!(type: Feed::FILE, key: "invoice.pdf", title: "invoice.pdf", parent: @message)
      @note = Feed.create!(type: Feed::NOTE, key: "Shopping", title: "Shopping")
      @tag = Feed.tag!("receipts")
    end

    connect!(@tenant)
  end

  test "several types are asked for at once, and the extracted can be left out" do
    body = execute(FEEDS, variables: { types: [ Feed::FILE, Feed::NOTE ], topLevel: true })
    titles = body.dig("data", "feeds", "nodes").map { |node| node["title"] }

    assert_equal %w[Shopping march.eml], titles.sort
  end

  test "left alone, the extracted are listed with everything else" do
    body = execute(FEEDS, variables: { types: [ Feed::FILE ] })

    assert_equal %w[invoice.pdf march.eml], body.dig("data", "feeds", "nodes").map { |node| node["title"] }.sort
  end

  test "a feed names what was extracted from it and what it was extracted from" do
    message = execute(FEED, variables: { id: @message.id }).dig("data", "feed")
    attachment = execute(FEED, variables: { id: @attachment.id }).dig("data", "feed")

    assert_equal [ "invoice.pdf" ], message["children"].map { |child| child["title"] }
    assert_equal "march.eml", attachment.dig("parent", "title")
    assert_not message["staged"]
  end

  test "the type counts are of what the catalog lists, leaving out what was extracted" do
    counts = execute(TYPES).dig("data", "types").to_h { |entry| [ entry["type"], entry["count"] ] }

    assert_equal 1, counts[Feed::FILE]
    assert_equal 1, counts[Feed::NOTE]
  end

  test "a row names the file it was extracted from" do
    body = execute(<<~GQL, variables: { types: [ Feed::FILE ] })
      query($types: [String!]) { feeds(types: $types) { nodes { title parent { title } } } }
    GQL
    parents = body.dig("data", "feeds", "nodes").to_h { |node| [ node["title"], node.dig("parent", "title") ] }

    assert_equal({ "march.eml" => nil, "invoice.pdf" => "march.eml" }, parents)
  end

  test "what a feed is connected to narrows by tag rather than replacing it" do
    Tenant.switch(@tenant) do
      Edge.between!(@tag, @message)
      Edge.between!(@tag, @attachment)
      Edge.between!(@note, @message)
      Edge.between!(@note, @tag)
    end

    body = execute(<<~GQL, variables: { connectedTo: @note.id })
      query($connectedTo: ID) { feeds(tag: "receipts", connectedTo: $connectedTo) { nodes { title } } }
    GQL

    assert_equal %w[march.eml], body.dig("data", "feeds", "nodes").map { |node| node["title"] }
  end

  test "a feed's analyses come newest first" do
    Tenant.switch(@tenant) do
      Analysis.open!(feed: @message, cause: "upload")
      Analysis.open!(feed: @message, cause: "manual")
    end

    causes = execute(FEED, variables: { id: @message.id }).dig("data", "feed", "analyses").map { |held| held["cause"] }

    assert_equal %w[manual upload], causes
  end

  private

    def execute(query, variables: nil)
      post "/graphql",
           params: { query: query, variables: variables&.to_json }.compact,
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test" }.merge(bearer)

      response.parsed_body
    end

    def bearer
      token = issuer.mint(
        subdomain: @tenant.subdomain, scopes: Grant::SCOPES,
        audience: "http://#{@tenant.subdomain}.xixo.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end
end
