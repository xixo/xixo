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

  DELETE_RESOURCE = <<~GQL.freeze
    mutation($id: ID!) { deleteResource(input: { id: $id }) { deleted places } }
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

  test "a resource in use is refused deletion until it is put away" do
    body = execute(DELETE_RESOURCE, variables: { id: @storage.id })

    assert_nil body.dig("data", "deleteResource")
    assert_equal "database is still in use; put it away before deleting it", body.dig("errors", 0, "message")
    Tenant.switch(@tenant) { assert Resource.exists?(@storage.id) }
  end

  test "deleting a put-away resource drops its references, forgets what lived only there, and frees its key" do
    Tenant.switch(@tenant) do
      @elsewhere = Resource::Database.create!(key: "elsewhere", name: "Elsewhere")
      @elsewhere.upload("copy.txt", "four thousand two hundred")
      @kept = create_feed(key: "both.txt", resource: @storage, locator_key: "both.txt")
      @kept.references.create!(resource: @elsewhere, locator_key: "copy.txt", locator: { "key" => "copy.txt" })
      @noted = create_feed(key: "noted.txt", resource: @storage, locator_key: "noted.txt")
      @noted.update!(note: "the one with the receipt")
      Run.start!(kind: "sync", resource: @storage).update_columns(status: "done")
    end

    execute(ARCHIVE, variables: { id: @storage.id, archived: true })
    body = execute(DELETE_RESOURCE, variables: { id: @storage.id })

    assert_equal true, body.dig("data", "deleteResource", "deleted")
    assert_equal 3, body.dig("data", "deleteResource", "places")

    perform_enqueued_jobs(only: ForgetPlacelessJob)

    Tenant.switch(@tenant) do
      assert_nil Resource.find_by(id: @storage.id)
      assert_nil Feed.find_by(id: @item.id), "a feed whose only place went is forgotten"
      assert_equal [ @elsewhere.id ], @kept.reload.references.pluck(:resource_id)
      assert_empty @noted.reload.references, "a feed somebody wrote a note on outlives its places"
      assert_equal 0, Run.where(resource_id: @storage.id).count
      assert_equal 0, ResourceBlob.where(resource_id: @storage.id).count
      assert Resource::Database.create!(key: "database", name: "Storage again"), "the key is free again"
    end
  end

  test "a transport something is still reached through is refused deletion" do
    Tenant.switch(@tenant) do
      @tailnet = Resource::Tailnet.create!(key: "tailnet", name: "Tailnet")
      Resource::Webdav.create!(key: "shares", details: { "url" => "http://100.64.1.2/dav/" }, via: @tailnet,
                               archived_at: Time.current)
      @tailnet.update!(archived_at: Time.current)
    end

    body = execute(DELETE_RESOURCE, variables: { id: @tailnet.id })

    assert_equal "tailnet cannot be deleted while shares is reached through it", body.dig("errors", 0, "message")
    Tenant.switch(@tenant) { assert Resource.exists?(@tailnet.id) }
  end

  test "a store xixo keeps for itself cannot be deleted" do
    derived = Tenant.switch(@tenant) { Resource.internal!(:derived) }

    body = execute(DELETE_RESOURCE, variables: { id: derived.id })

    assert_match(/no resource with id/, body.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert Resource.exists?(derived.id) }
  end

  test "deleting a resource needs the command scope and is in the audit trail" do
    execute(ARCHIVE, variables: { id: @storage.id, archived: true })

    read = execute(DELETE_RESOURCE, scopes: %w[xixo:resources:read], variables: { id: @storage.id })
    assert_nil read.dig("data", "deleteResource")
    Tenant.switch(@tenant) { assert Resource.exists?(@storage.id) }

    execute(DELETE_RESOURCE, variables: { id: @storage.id })

    Tenant.switch(@tenant) do
      deleted = AuditEvent.find_by!(action: "delete_resource")

      assert_equal "deleted database, which held 1 place", deleted.told
      assert_equal({ "type" => "database", "key" => "database", "places" => 1 }, deleted.arguments)
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
