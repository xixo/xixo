require "test_helper"

class SharedResourcesTest < ActionDispatch::IntegrationTest
  RESOURCES = "{ administrator resources { key manageable } }".freeze

  setup do
    @tenant = Tenant.create!(subdomain: "shared-#{SecureRandom.hex(4)}", name: "Shared")

    connect!(@tenant)

    Tenant.switch(@tenant) do
      @news = Resource::Rss.create!(key: "news", details: { "url" => "https://news.example.com/feed.xml" })
      @mine = Resource::Rss.create!(key: "mine", owner_subject: "bob", details: { "url" => "https://bob.example.com/feed.xml" })
      @store = Resource::Database.create!(key: "store")
    end
  end

  test "a member is told they do not administer, and manages only their own places" do
    listed = graphql(Grant::SIGN_IN, RESOURCES).dig("data")

    assert_equal false, listed["administrator"]
    assert_equal({ "mine" => true, "news" => false, "store" => false },
                 listed["resources"].to_h { |held| [ held["key"], held["manageable"] ] })
  end

  test "an administrator manages every shared place" do
    listed = graphql(Grant::SCOPES, RESOURCES).dig("data")

    assert_equal true, listed["administrator"]
    assert(listed["resources"].select { |held| held["key"] != "mine" }.all? { |held| held["manageable"] })
  end

  test "a member cannot change, put away, delete, or attach a place everyone shares" do
    refusals = [
      %(mutation { updateResource(input: { id: "#{@news.id}", name: "Gone" }) { resource { name } } }),
      %(mutation { archiveResource(input: { id: "#{@news.id}", archived: true }) { resource { key } } }),
      %(mutation { deleteResource(input: { id: "#{@news.id}" }) { deleted } }),
      %(mutation { setSyncInterval(input: { id: "#{@news.id}", seconds: 3600 }) { resource { key } } }),
      %(mutation { attachResource(input: { type: "rss", key: "theirs", settings: { url: "https://x.example.com/feed.xml" } }) { resource { key } } })
    ]

    refusals.each do |mutation|
      body = graphql(Grant::SIGN_IN, mutation)

      assert_match(/administrator/, body.dig("errors", 0, "message").to_s + body.dig("data").to_json, mutation)
    end

    Tenant.switch(@tenant) do
      @news.reload

      assert_not_equal "Gone", @news.name
      assert_nil @news.archived_at
      assert_nil @news.sync_interval
      assert_nil Resource.find_by(key: "theirs")
    end
  end

  test "a member cannot choose the default storage" do
    body = graphql(Grant::SIGN_IN, %(mutation { setDefaultStorage(input: { id: "#{@store.id}" }) { resource { key } } }))

    assert_match(/only an administrator chooses/, body.dig("errors", 0, "message"))
    Tenant.switch(@tenant) { assert_not @store.reload.default_storage? }
  end

  test "a member still changes and puts away a place that is only theirs" do
    body = graphql(Grant::SIGN_IN, %(mutation { archiveResource(input: { id: "#{@mine.id}", archived: true }) { resource { key } } }))

    assert_equal "mine", body.dig("data", "archiveResource", "resource", "key")
  end

  test "an administrator changes a place everyone shares" do
    body = graphql(Grant::SCOPES, %(mutation { setSyncInterval(input: { id: "#{@news.id}", seconds: 3600 }) { resource { key } } }))

    assert_equal "news", body.dig("data", "setSyncInterval", "resource", "key")
  end

  private

    def graphql(scopes, query)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: "bob", scopes: scopes,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")
      post "/graphql", params: { query: query }, headers: { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }

      response.parsed_body
    end
end
