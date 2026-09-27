require "test_helper"

class TaggingTest < ActionDispatch::IntegrationTest
  TAG = <<~GQL.freeze
    mutation($ids: [ID!]!, $tag: String!) {
      tagFeeds(input: { ids: $ids, tag: $tag }) { feeds { id } }
    }
  GQL

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "tag-#{SecureRandom.hex(4)}", name: "Tagging")

    Tenant.switch(@tenant) do
      @one = create_feed(mime: "image/jpeg", title: "IMG_1.jpg", locator_key: "a/IMG_1.jpg")
      @two = create_feed(mime: "image/jpeg", title: "IMG_2.jpg", locator_key: "a/IMG_2.jpg")
    end

    SearchIndex.refresh!
    connect!(@tenant)
  end

  test "several items are filed under one tag, and a search then finds them by it" do
    body = execute(TAG, variables: { ids: [ @one.id, @two.id ], tag: "  wonky   name " })

    assert_equal [ @one.id.to_s, @two.id.to_s ], body.dig("data", "tagFeeds", "feeds").map { |held| held["id"] }
    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      assert_equal [ "wonky name" ], @one.reload.tags.pluck(:key)
      assert_equal [ @one.id, @two.id ].sort, Feed.tagged("wonky name").pluck(:id).sort
      assert_equal [ @one.id, @two.id ].sort, Feed.search("wonky name").where.not(type: Feed::TAG).pluck(:id).sort
    end
  end

  test "tagging twice files it once" do
    2.times { execute(TAG, variables: { ids: [ @one.id ], tag: "twice" }) }

    Tenant.switch(@tenant) { assert_equal 1, @one.reload.tags.where(key: "twice").count }
  end

  test "a blank tag is refused" do
    body = execute(TAG, variables: { ids: [ @one.id ], tag: "   " })

    assert_nil body.dig("data", "tagFeeds")
    assert_match(/needs a name/, body.dig("errors", 0, "message"))
  end

  test "one item that does not exist refuses the lot" do
    body = execute(TAG, variables: { ids: [ @one.id, 0 ], tag: "partial" })

    assert_match(/no feed with id 0/, body.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert_empty @one.reload.tags.where(key: "partial") }
  end

  test "a tag cannot itself be tagged" do
    held = Tenant.switch(@tenant) { Feed.tag!("holder") }

    body = execute(TAG, variables: { ids: [ held.id ], tag: "nested" })

    assert_match(/cannot itself be tagged/, body.dig("errors", 0, "message"))
  end

  test "tagging needs the write scope, not the read one" do
    body = execute(TAG, scopes: %w[uris:catalog:read], variables: { ids: [ @one.id ], tag: "nope" })

    assert_nil body.dig("data", "tagFeeds")
    Tenant.switch(@tenant) { assert_empty @one.reload.tags.where(key: "nope") }
  end

  private

    def host_for(tenant)
      { "HOST" => "#{tenant.subdomain}.uris.test" }
    end

    def bearer(tenant, scopes: Grant::SCOPES)
      token = issuer.mint(
        subdomain: tenant.subdomain, scopes: scopes,
        audience: "http://#{tenant.subdomain}.uris.test/mcp"
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
