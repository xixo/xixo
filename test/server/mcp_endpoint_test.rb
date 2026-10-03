require "test_helper"

class McpEndpointTest < ActionDispatch::IntegrationTest
  include McpClient

  ALL = Grant::SCOPES

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "mcp-#{SecureRandom.hex(4)}", name: "Endpoint")
    @other = Tenant.create!(subdomain: "mcp-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @resource = Resource::S3.create!(key: "endpoint-bucket", name: "Bucket",
                                       details: { "endpoint" => "http://127.0.0.1:1" })
      @feed = create_feed(mime: "application/pdf", title: "March invoice", locator_key: "invoices/march.pdf",
                          resource: @resource, locator: { "bucket" => "endpoint-bucket" })
    end

    Tenant.switch(@other) do
      @theirs = create_feed(mime: "application/pdf", title: "Their invoice", locator_key: "invoices/theirs.pdf")
    end

    SearchIndex.refresh!
  end

  test "an unauthenticated call answers with the challenge that starts the OAuth flow" do
    post "/mcp", headers: host_for(@tenant), params: rpc("initialize"), as: :json

    assert_response :unauthorized

    challenge = response.headers["WWW-Authenticate"]

    assert_match(/\ABearer /, challenge)
    assert_includes challenge, %(resource_metadata="#{origin_for(@tenant)}/.well-known/oauth-protected-resource")
    assert_includes challenge, %(scope="#{Grant::OFFERED.keys.join(' ')}")
  end

  test "the metadata the challenge points at names this tenant's issuer" do
    get "/.well-known/oauth-protected-resource", headers: host_for(@tenant)

    assert_response :success

    metadata = response.parsed_body

    assert_equal "#{origin_for(@tenant)}/mcp", metadata["resource"]
    assert_equal [ issuer.url_for(@tenant.subdomain) ], metadata["authorization_servers"]
    assert_equal Grant::OFFERED.keys, metadata["scopes_supported"]
    assert_equal Grant::OFFERED, metadata["scope_descriptions"],
                 "an auth server has no other way to render these as sentences"
  end

  test "a client is offered the scopes its tools check, and never the settings ones" do
    get "/.well-known/oauth-protected-resource", headers: host_for(@tenant)

    offered = response.parsed_body["scopes_supported"]

    assert_includes offered, "uris:resources:command"
    assert_empty offered & Grant::SETTINGS,
                 "an authorization server that bounds what clients register refuses the whole request over one of these"
  end

  test "a token minted for one tenant is refused by another" do
    post "/mcp", headers: host_for(@other).merge(bearer(@tenant, ALL)),
                 params: rpc("tools/list"), as: :json

    assert_response :unauthorized
  end

  test "an expired token is refused" do
    travel_to 2.hours.ago do
      @stale = bearer(@tenant, ALL)
    end

    post "/mcp", headers: host_for(@tenant).merge(@stale), params: rpc("tools/list"), as: :json

    assert_response :unauthorized
  end

  test "the token decides which tools exist at all" do
    assert_equal %w[search feed], listed_tools([ "uris:catalog:read" ])
    assert_equal %w[search feed connect], listed_tools(%w[uris:catalog:read uris:catalog:write])
    assert_equal %w[search feed connect resource], listed_tools(ALL)
  end

  test "a tool outside the grant is not callable, not merely unlisted" do
    reply = call(@tenant, [ "uris:catalog:read" ], "tools/call",
                 name: "resource", arguments: { key: @resource.key })

    assert_nil reply["result"]
    assert_match(/Tool not found/, reply.dig("error", "data"))
  end

  test "a command outside the grant is absent from the schema rather than refused at the call" do
    read = tool_schema(%w[uris:resources:read], "resource")
    both = tool_schema(%w[uris:resources:read uris:resources:command], "resource")

    assert_equal Tool::Resources::READ, read.dig("properties", "do", "enum")
    assert_includes both.dig("properties", "do", "enum"), "sync"
    assert_not_includes read.dig("properties", "do", "enum"), "sync"
  end

  test "keeping one object takes the command scope, and catalogues that object alone" do
    Tenant.switch(@tenant) do
      @bucket = Resource::S3.create!(key: "kept-bucket", name: "Kept", details: { "endpoint" => FakeS3::ENDPOINT },
                                     credentials: { "access_key_id" => "k", "secret_access_key" => "s" })
    end
    @bucket.client.put_object(bucket: "kept-bucket", key: "reports/q3.pdf", body: "the third quarter")
    @bucket.client.put_object(bucket: "kept-bucket", key: "reports/q4.pdf", body: "the fourth quarter")

    assert_not_includes tool_schema(%w[uris:resources:read], "resource").dig("properties", "do", "enum"), "keep"
    assert_not_includes tool_schema(%w[uris:resources:read uris:web:keep], "resource").dig("properties", "do", "enum"), "keep"

    refused = call(@tenant, %w[uris:resources:read], "tools/call",
                   name: "resource", arguments: { key: "kept-bucket", do: "keep", input: { key: "reports/q3.pdf" } })
    assert refused.dig("result", "isError")

    kept = tool(@tenant, ALL, "resource", key: "kept-bucket", do: "keep", input: { key: "reports/q3.pdf" })

    assert_equal "reports/q3.pdf", kept["key"]

    Tenant.switch(@tenant) do
      assert_equal [ "reports/q3.pdf" ], Reference.where(resource_id: @bucket.id).pluck(:locator_key)
      assert_equal kept["id"], feed_at("reports/q3.pdf").id.to_s
    end
  end

  test "keeping pages from the web offers snapshot and nothing else a command could do" do
    keep = tool_schema(%w[uris:resources:read uris:web:keep], "resource")

    assert_includes keep.dig("properties", "do", "enum"), "snapshot"
    assert_empty keep.dig("properties", "do", "enum") & (Tool::Resources::WRITE - Tool::Resources::KEEPING)
  end

  test "keeping pages from the web snapshots only through a resource that renders them" do
    reply = call(@tenant, %w[uris:resources:read uris:web:keep], "tools/call",
                 name: "resource", arguments: { key: @resource.key, do: "snapshot", input: { url: "https://example.com" } })

    assert reply.dig("result", "isError")
    assert_match(/does not keep pages/, reply.dig("result", "content", 0, "text"))

    bare = call(@tenant, %w[uris:resources:read], "tools/call",
                name: "resource", arguments: { key: @resource.key, do: "snapshot", input: { url: "https://example.com" } })

    assert bare.dig("result", "isError")
  end

  test "search returns this tenant's feeds and never another's" do
    result = tool(@tenant, ALL, "search", query: "invoice")

    assert_equal [ @feed.id.to_s ], result["feeds"].map { |feed| feed["id"] }
  end

  test "a feed belonging to another tenant cannot be fetched by id" do
    reply = call(@tenant, ALL, "tools/call",
                 name: "feed", arguments: { id: @theirs.id.to_s })

    assert reply.dig("result", "isError")
    assert_match(/no feed with id/, reply.dig("result", "content", 0, "text"))
  end

  test "an agent places a staged file with the feed tool, and must say why" do
    staged = Tenant.switch(@tenant) do
      store = Resource::Database.create!(key: "shelf", name: "Shelf")
      feed = Feed.create!(type: Feed::FILE, key: "note.txt", title: "note.txt")
      Staged.stage!(feed, path: "note.txt", body: "hello", mime: "text/plain")

      assert_equal %w[endpoint-bucket shelf], tool(@tenant, ALL, "feed", id: feed.id.to_s)["staged"]["accepted_by"]

      [ feed, store ]
    end

    feed, store = staged

    reasonless = call(@tenant, ALL, "tools/call", name: "feed",
                                                  arguments: { id: feed.id.to_s, do: "place", resource: store.key })

    assert reasonless.dig("result", "isError")

    misnamed = call(@tenant, ALL, "tools/call", name: "feed",
                                                arguments: { id: feed.id.to_s, do: "place", reason: "it is a note",
                                                             resource: "shelf: Shelf (default storage)" })

    assert_equal "no resource called shelf: Shelf (default storage); the ones that accept this feed are " \
                 "endpoint-bucket and shelf", misnamed.dig("result", "content", 0, "text")

    placed = tool(@tenant, ALL, "feed", id: feed.id.to_s, do: "place", resource: "`#{store.key}`",
                                        reason: "it is a note")

    assert_nil placed["staged"]
    assert_equal [ store.id.to_s ], placed["references"].map { |reference| reference["resource_id"] }
  end

  test "connect files a feed under a tag by its name, making the tag the first time" do
    filed = tool(@tenant, ALL, "connect", a: @feed.id.to_s, tag: "receipts")

    assert filed["connected"]
    Tenant.switch(@tenant) do
      assert_equal [ "receipts" ], @feed.reload.tags.map(&:key)
      assert_equal 1, Feed.tags.by_key("receipts").count
    end

    tool(@tenant, ALL, "connect", a: @feed.id.to_s, tag: "tag:receipts")
    Tenant.switch(@tenant) { assert_equal 1, Feed.tags.count }
  end

  test "severing a tag that does not exist is refused rather than making it" do
    reply = call(@tenant, ALL, "tools/call", name: "connect",
                                             arguments: { a: @feed.id.to_s, tag: "nonexistent", connected: false })

    assert reply.dig("result", "isError")
    Tenant.switch(@tenant) { assert_equal 0, Feed.tags.count }
  end

  test "a feed the model makes badly comes back to it as an error instead of failing the run" do
    reply = call(@tenant, ALL, "tools/call", name: "feed", arguments: { do: "create", title: "" })

    assert reply.dig("result", "isError")
    assert_match(/can't be blank/, reply.dig("result", "content", 0, "text"))
  end

  test "reading a page through a fetch resource needs the web scope" do
    Tenant.switch(@tenant) { Resource::Curl.create!(key: "curl", name: "Curl") }

    reply = call(@tenant, %w[uris:resources:read], "tools/call",
                 name: "resource", arguments: { key: "curl", do: "get", input: { url: "https://example.com" } })

    assert reply.dig("result", "isError")
    assert_match(/uris:web:read/, reply.dig("result", "content", 0, "text"))
  end

  test "describe advertises the vocabulary the resource accepts" do
    described = tool(@tenant, ALL, "resource", key: @resource.key, do: "describe")

    assert_equal "s3", described["type"]
    assert_includes described["commands"].keys, "list"
    assert_not_includes described.to_json, "secret_access_key"
  end

  test "an unknown action is refused before the adapter is reached" do
    reply = call(@tenant, ALL, "tools/call", name: "resource",
                 arguments: { key: @resource.key, do: "rm", input: {} })

    assert reply.dig("result", "isError")
    assert_match(/value at `\/do` is not one of/, reply.dig("result", "content", 0, "text"))
  end

  test "sync queues a run against the named resource" do
    result = nil

    assert_enqueued_with(job: SyncResourceJob,
                         args: ->(args) { args.first(2) == [ @tenant.id, @resource.id ] }) do
      result = tool(@tenant, ALL, "resource", key: @resource.key, do: "sync")

      assert_equal "sync", result["kind"]
    end

    Tenant.switch(@tenant) do
      run = Run.find(result["id"])

      assert_equal "sync", run.kind
      assert_equal @resource, run.resource
    end
  end

  test "a second sync of a resource already syncing is refused, with no second run" do
    tool(@tenant, ALL, "resource", key: @resource.key, do: "sync")

    assert_no_difference -> { Tenant.switch(@tenant) { Run.count } } do
      again = tool(@tenant, ALL, "resource", key: @resource.key, do: "sync")

      assert_not again["started"]
      assert_match(/already syncing/, again["reason"])
    end
  end

  test "checking dials the resource and writes down what it found, so it takes the command scope" do
    assert_not_includes tool_schema(%w[uris:resources:read], "resource").dig("properties", "do", "enum"), "check"

    reply = call(@tenant, %w[uris:resources:read], "tools/call",
                 name: "resource", arguments: { key: @resource.key, do: "check" })

    assert reply.dig("result", "isError")
    Tenant.switch(@tenant) { assert_nil @resource.reload.checked_at }
  end

  test "the stores uris keeps for itself are neither listed nor reachable by key" do
    Tenant.switch(@tenant) { Resource.internal!(:children) }

    listed = tool(@tenant, ALL, "resource", do: "list")["resources"].map { |resource| resource["key"] }
    assert_not_includes listed, "children"

    reply = call(@tenant, ALL, "tools/call", name: "resource", arguments: { key: "children", do: "list" })
    assert reply.dig("result", "isError")
  end

  test "check answers with the failure instead of becoming one" do
    checked = tool(@tenant, ALL, "resource", key: @resource.key, do: "check")

    assert_not checked["healthy"]
    assert_not_nil checked["error"]
  end

  test "a resource carries what its last check found" do
    tool(@tenant, ALL, "resource", key: @resource.key, do: "check")

    listed = tool(@tenant, ALL, "resource", do: "list")["resources"].first

    assert_not_nil listed["checked_at"]
    assert_not_nil listed["check_error"]
  end

  test "a run started through a tool is visible and cancellable through one" do
    started = tool(@tenant, ALL, "resource", key: @resource.key, do: "sync")

    listed = tool(@tenant, ALL, "resource", key: @resource.key, do: "runs")["runs"]

    assert_equal [ started["id"] ], listed.map { |run| run["id"] }
    assert_equal "queued", listed.first["status"]

    cancelled = tool(@tenant, ALL, "resource", key: @resource.key, do: "cancel",
                     input: { id: started["id"] })

    assert_equal "cancelled", cancelled["status"]

    again = tool(@tenant, ALL, "resource", key: @resource.key, do: "runs")["runs"]

    assert_equal "cancelled", again.first["status"]
  end

  test "one tenant cannot see or cancel another tenant's run" do
    started = tool(@tenant, ALL, "resource", key: @resource.key, do: "sync")

    Tenant.switch(@other) do
      @elsewhere = Resource::S3.create!(key: "elsewhere-bucket", name: "Bucket",
                                        details: { "endpoint" => "http://127.0.0.1:1" })
    end

    assert_empty tool(@other, ALL, "resource", key: @elsewhere.key, do: "runs")["runs"]

    reply = call(@other, ALL, "tools/call", name: "resource",
                 arguments: { key: @elsewhere.key, do: "cancel", input: { id: started["id"] } })

    assert reply.dig("result", "isError")
    assert_match(/no run with that id/, reply.dig("result", "content", 0, "text"))
  end

  test "export refuses a destination that is not storage" do
    Tenant.switch(@tenant) { Resource::Web.create!(key: "the-web", name: "The web") }

    reply = call(@tenant, ALL, "tools/call", name: "resource",
                 arguments: { key: "the-web", do: "export", input: {} })

    assert reply.dig("result", "isError")
    assert_match(/is not storage/, reply.dig("result", "content", 0, "text"))
  end

  test "export queues a run against the destination it names" do
    storage = Tenant.switch(@tenant) do
      Resource::Database.create!(key: "database", name: "Storage")
    end

    assert_enqueued_with(job: ExportItemsJob,
                         args: ->(args) { args.first(2) == [ @tenant.id, storage.id ] }) do
      queued = tool(@tenant, ALL, "resource", key: storage.key, do: "export")

      assert_equal "export", queued["kind"]
    end
  end

  private

    def listed_tools(scopes)
      call(@tenant, scopes, "tools/list").dig("result", "tools").map { |tool| tool["name"] }
    end

    def tool_schema(scopes, name)
      call(@tenant, scopes, "tools/list").dig("result", "tools")
                                        .find { |tool| tool["name"] == name }
                                        .fetch("inputSchema")
    end
end
