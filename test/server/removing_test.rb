require "test_helper"

class RemovingTest < ActionDispatch::IntegrationTest
  ARCHIVE = <<~GQL.freeze
    mutation($id: ID!, $archived: Boolean!) {
      archiveResource(input: { id: $id, archived: $archived }) {
        resource { id key archivedAt }
      }
    }
  GQL

  RESOURCES = <<~GQL.freeze
    query($archived: Boolean) { resources(archived: $archived) { key archivedAt } }
  GQL

  FORGET = <<~GQL.freeze
    mutation($id: ID!) { forgetFeed(input: { id: $id }) { forgotten places } }
  GQL

  DELETE_FEED = <<~GQL.freeze
    mutation($id: ID!) { deleteFeed(input: { id: $id }) { deleted kept } }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "gone-#{SecureRandom.hex(4)}", name: "Removing")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "database", name: "Storage")
      @storage.upload("invoice.txt", "four thousand two hundred")
    end

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @storage.id) }

    Tenant.switch(@tenant) { @item = feed_at("invoice.txt") }

    connect!(@tenant)
  end

  def still_held?
    Tenant.switch(@tenant) do
      @storage.reload.download({ "key" => "invoice.txt" }).read.present?
    end
  end

  test "an archived resource leaves the list, keeps what it catalogued, and comes back" do
    execute(ARCHIVE, variables: { id: @storage.id, archived: true })

    assert_empty execute(RESOURCES).dig("data", "resources")

    put_away = execute(RESOURCES, variables: { archived: true }).dig("data", "resources")

    assert_equal [ "database" ], put_away.map { |held| held["key"] }
    assert_not_nil put_away.first["archivedAt"]

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count, "archiving a resource does not throw away the catalog"
      assert_equal 1, Reference.count
    end

    assert still_held?, "nor does it reach through to what the resource holds"

    execute(ARCHIVE, variables: { id: @storage.id, archived: false })

    assert_equal [ "database" ], execute(RESOURCES).dig("data", "resources").map { |h| h["key"] }
  end

  test "a resource that refuses to be put away says why rather than half doing it" do
    gone = execute(ARCHIVE, variables: { id: "9999999", archived: true })

    assert_nil gone.dig("data", "archiveResource")
    assert_match(/no resource with id/, gone.dig("errors", 0, "message"))
  end

  test "forgetting an item drops every place it lived without touching any of them" do
    body = execute(FORGET, variables: { id: @item.id })

    assert_equal true, body.dig("data", "forgetFeed", "forgotten")
    assert_equal 1, body.dig("data", "forgetFeed", "places")

    Tenant.switch(@tenant) do
      assert_equal 0, Feed.files.count
      assert_equal 0, Reference.count
    end

    assert still_held?, "the bytes belong to the resource, not to the catalog entry"
  end

  test "deleting a feed keeps the items it wrote and says how many outlived it" do
    Tenant.switch(@tenant) do
      @feed = Feed.create!(type: Feed::ADDRESS, key: "/buy")
      @feed.create_schedule!(prompt: "find things worth buying")
      @minted = Feed.create!(type: Feed::FILE, key: "A thing", title: "A thing", origin: "feed")
      @feed.connect!(@minted)
    end

    body = execute(DELETE_FEED, variables: { id: @feed.id })

    assert_equal true, body.dig("data", "deleteFeed", "deleted")
    assert_equal 1, body.dig("data", "deleteFeed", "kept")

    Tenant.switch(@tenant) do
      assert_nil Feed.find_by(id: @feed.id)
      assert_equal @minted, Feed.find_by(id: @minted.id)
      assert_empty @minted.reload.connected, "the edge went with the feed, the thing did not"
      assert_nil Schedule.find_by(feed_id: @feed.id)
    end
  end

  test "removing anything needs a write scope, not a read one" do
    forget = execute(FORGET, scopes: %w[xixo:catalog:read], variables: { id: @item.id })
    archive = execute(ARCHIVE, scopes: %w[xixo:resources:read],
                               variables: { id: @storage.id, archived: true })

    assert_nil forget.dig("data", "forgetFeed")
    assert_nil archive.dig("data", "archiveResource")

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_nil @storage.reload.archived_at
    end
  end

  test "what was removed is in the audit trail" do
    execute(FORGET, variables: { id: @item.id })
    execute(ARCHIVE, variables: { id: @storage.id, archived: true })

    Tenant.switch(@tenant) do
      forgotten = AuditEvent.find_by(action: "forget_feed")
      archived = AuditEvent.find_by(action: "archive_resource")

      assert_equal "ok", forgotten.status
      assert_equal "invoice.txt", forgotten.arguments["title"]
      assert_equal 1, forgotten.arguments["places"]
      assert_equal "database", archived.arguments["key"]
      assert_equal "forgot invoice.txt, which lived in 1 place", forgotten.told
      assert_equal "archived database", archived.told
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
