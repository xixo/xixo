require "test_helper"

class PersonalResourcesTest < ActionDispatch::IntegrationTest
  LISTED = [ { "name" => "search", "description" => "Search Notion", "input_schema" => { "properties" => {} } } ].freeze

  RESOURCES = "{ resources { key personal } }".freeze

  ATTACH = <<~GQL.freeze
    mutation($settings: JSON, $personal: Boolean) {
      attachResource(input: { type: "rss", key: "mine", settings: $settings, personal: $personal }) {
        resource { id personal }
      }
    }
  GQL

  setup do
    @tenant = Tenant.create!(subdomain: "personal-#{SecureRandom.hex(4)}", name: "Personal")

    connect!(@tenant)

    Tenant.switch(@tenant) do
      @shared = Resource::Rss.create!(key: "news", details: { "url" => "https://news.example.com/feed.xml" })
      @ada = Resource::Mcp.create!(key: "notion", owner_subject: "ada",
                                   details: { "url" => "https://mcp.notion.test/mcp", "auth" => "masks", "provider" => "notion", "tools" => LISTED })
    end
  end

  def headers(subject)
    token = issuer.mint(subdomain: @tenant.subdomain, subject: subject, scopes: Grant::SCOPES,
                        audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

    { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }
  end

  def graphql(subject, query, **variables)
    post "/graphql", params: { query: query, variables: variables.to_json }, headers: headers(subject)

    response.parsed_body
  end

  def grant_for(subject)
    Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => Grant::SCOPES.join(" ")))
  end

  def as(grant)
    Tenant.switch(@tenant) do
      Current.grant = grant
      yield
    ensure
      Current.grant = nil
    end
  end

  test "a personal resource is listed for its owner and nobody else" do
    assert_equal %w[news notion], graphql("ada", RESOURCES).dig("data", "resources").pluck("key").sort
    assert_equal %w[news], graphql("bob", RESOURCES).dig("data", "resources").pluck("key")
    assert_equal true, graphql("ada", RESOURCES).dig("data", "resources").find { |one| one["key"] == "notion" }["personal"]
  end

  test "somebody else cannot act on a personal resource by its id" do
    body = graphql("bob", %(mutation { checkResource(input: { id: "#{@ada.id}" }) { ok } }))

    assert_match(/no resource with id/, body.dig("errors", 0, "message"))

    get "/resources/#{@ada.id}/connect", headers: headers("bob")

    assert_response :not_found
  end

  test "attaching one as only mine makes it mine" do
    body = graphql("bob", ATTACH, settings: { "url" => "https://bob.example.com/feed.xml" }, personal: true)

    assert body.dig("data", "attachResource", "resource", "personal"), body.inspect
    assert_equal "bob", Tenant.switch(@tenant) { Resource.find_by!(key: "mine").owner_subject }
    assert_equal %w[mine news], graphql("bob", RESOURCES).dig("data", "resources").pluck("key").sort
    assert_equal %w[news notion], graphql("ada", RESOURCES).dig("data", "resources").pluck("key").sort
  end

  test "the resource tool neither lists nor reaches somebody else's resource" do
    listed = as(grant_for("bob")) { JSON.parse(Tool::Resources.call(server_context: {}).content.first[:text]) }

    assert_equal %w[news], listed["resources"].pluck("key")

    refused = as(grant_for("bob")) { Tool::Resources.call(server_context: {}, key: "notion", do: "describe") }

    assert refused.error?
    assert_match(/no resource called notion/, refused.content.first[:text])

    described = as(grant_for("ada")) { Tool::Resources.call(server_context: {}, key: "notion", do: "describe") }

    refute described.error?
  end

  test "a personal MCP server's tools are offered to its owner alone" do
    assert_includes as(grant_for("ada")) { grant_for("ada").proxied.map(&:tool_name) }, "notion__search"
    assert_empty as(grant_for("bob")) { grant_for("bob").proxied }
  end

  test "somebody else's proxied tool refuses to reach the server, even handed to them" do
    tool = as(grant_for("ada")) { grant_for("ada").proxied.first }

    answered = as(grant_for("bob")) { tool.call(server_context: {}) }

    assert answered.error?
    assert_not_requested :post, "https://mcp.notion.test/mcp"
  end

  test "the MCP server one person's tools were built for is never handed to somebody else" do
    ada, bob, carol = %w[ada bob carol].map { |subject| grant_for(subject) }

    Tenant.switch(@tenant) do
      refute_same McpTransports.for(tenant: @tenant, grant: ada), McpTransports.for(tenant: @tenant, grant: bob)
      assert_same McpTransports.for(tenant: @tenant, grant: bob), McpTransports.for(tenant: @tenant, grant: carol)
    end
  ensure
    McpTransports.reset!
  end

  test "an agent working on a feed reaches only what everyone here can" do
    feed = Tenant.switch(@tenant) { create_feed(key: "memo", title: "Memo") }

    grant = Tenant.switch(@tenant) { feed.grant }

    reached = as(grant) { Resource.visible_to(Current.grant).pluck(:key) }

    assert_includes reached, "news"
    assert_not_includes reached, "notion"
  end

  test "a run somebody starts reaches their own resources, and speaks as the feed" do
    feed = Tenant.switch(@tenant) { create_feed(key: "memo", title: "Memo") }

    started = graphql("ada", %(mutation { runFeed(input: { id: "#{feed.id}" }) { analysis { id } } }))
    analysis = Tenant.switch(@tenant) { Analysis.find(started.dig("data", "runFeed", "analysis", "id")) }

    assert_equal "ada", analysis.requested_by

    grant = Tenant.switch(@tenant) { analysis.grant }
    reached = as(grant) { Resource.visible_to(Current.grant).pluck(:key) }

    assert_includes reached, "notion"
    assert_equal "feed:memo", grant.subject
    assert grant.agent?
  end

  test "a run somebody else starts on the same feed reaches only their own" do
    feed = Tenant.switch(@tenant) { create_feed(key: "memo", title: "Memo") }

    started = graphql("bob", %(mutation { runFeed(input: { id: "#{feed.id}" }) { analysis { id } } }))
    analysis = Tenant.switch(@tenant) { Analysis.find(started.dig("data", "runFeed", "analysis", "id")) }

    assert_equal "bob", analysis.requested_by
    assert_not_includes as(Tenant.switch(@tenant) { analysis.grant }) { Resource.visible_to(Current.grant).pluck(:key) }, "notion"
  end

  test "a run nobody started reaches only what everyone here can" do
    analysis = Tenant.switch(@tenant) { create_feed(key: "memo", title: "Memo").analyze!(cause: "sync") }

    assert_nil analysis.requested_by
    assert_not_includes as(Tenant.switch(@tenant) { analysis.grant }) { Resource.visible_to(Current.grant).pluck(:key) }, "notion"
  end

  test "a run an agent starts does not inherit whom the agent speaks for" do
    feed = Tenant.switch(@tenant) { create_feed(key: "memo", title: "Memo") }
    asked = Tenant.switch(@tenant) { Analysis.create!(feed: feed, cause: "manual", requested_by: "ada") }

    spawned = as(Tenant.switch(@tenant) { asked.grant }) { feed.analyze!(cause: "manual") }

    assert_nil spawned.requested_by
    assert_not_includes as(Tenant.switch(@tenant) { spawned.grant }) { Resource.visible_to(Current.grant).pluck(:key) }, "notion"
  end

  test "a shared web resource cannot keep its snapshots in somebody's personal storage" do
    Tenant.switch(@tenant) do
      Resource::S3.create!(key: "private-bucket", owner_subject: "ada",
                           details: { "endpoint" => "http://127.0.0.1:1", "bucket" => "b" })
      browser = Resource::Web.new(key: "browser", details: { "storage" => "private-bucket" })

      assert_raises(Resource::Unusable) { browser.storage }
    end
  end

  test "a snapshot is taken only with a browser the person asking can reach" do
    Tenant.switch(@tenant) { @browser = Resource::Web.create!(key: "adas-browser", owner_subject: "ada") }

    body = graphql("bob", %(mutation { snapshotUrl(input: { url: "https://example.com/" }) { run { id } } }))

    assert_match(/nothing here can render a page/, body.dig("errors", 0, "message"))
    assert_equal @browser, Tenant.switch(@tenant) { Resource.browser(grant_for("ada")) }
    assert_nil Tenant.switch(@tenant) { Resource.browser(grant_for("bob")) }
  end

  test "an agent is only told of web resources the grant it runs under can call" do
    Tenant.switch(@tenant) do
      Resource::Curl.create!(key: "adas-curl", owner_subject: "ada")
      Resource::Curl.create!(key: "curl")
      Resource::Web.create!(key: "adas-browser", owner_subject: "ada")

      feed = create_feed(key: "question", title: "Question")
      reach = Reach.new(feed.grant(scopes: Feed::ASKING_SCOPES))

      assert_equal %w[curl], reach.fetchers
      assert_empty reach.keepers
      assert_equal "curl", reach.read_call("https://example.com/")[:key]

      assert_equal %w[curl adas-curl], Reach.new(grant_for("ada")).fetchers
    end
  end

  test "a run on somebody else's resource can be neither seen nor cancelled" do
    run = Tenant.switch(@tenant) { Run.start!(kind: "sync", resource: @ada) }

    body = graphql("bob", %(mutation { cancelRun(input: { id: "#{run.id}" }) { cancelled } }))
    assert_match(/no run with id/, body.dig("errors", 0, "message"))

    assert_nil graphql("bob", %({ run(id: "#{run.id}") { id } })).dig("data", "run")
    assert_empty graphql("bob", "{ runs { nodes { id } } }").dig("data", "runs", "nodes")
    assert_equal [ run.id.to_s ], graphql("ada", "{ runs { nodes { id } } }").dig("data", "runs", "nodes").pluck("id")

    refused = as(grant_for("bob")) { Tool::Resources.call(server_context: {}, do: "cancel", key: "news", input: { id: run.id }) }
    assert refused.error?
    assert_match(/no run with that id/, refused.content.first[:text])

    assert Tenant.switch(@tenant) { run.reload.open? }
  end

  test "a personal resource is never where everyone's drops land" do
    Tenant.switch(@tenant) do
      bucket = Resource::S3.new(key: "private-bucket", owner_subject: "ada", default_storage: true,
                                details: { "endpoint" => "http://127.0.0.1:1", "bucket" => "b" })

      assert_not bucket.valid?
      assert_match(/only its owner's/, bucket.errors.full_messages.join)
    end
  end
end
