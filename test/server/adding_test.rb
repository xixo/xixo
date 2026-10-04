require "test_helper"
require_relative "../support/fake_feed_server"

class AddingTest < ActionDispatch::IntegrationTest
  NOTE = <<~GQL.freeze
    mutation($title: String, $body: String!) {
      addNote(input: { title: $title, body: $body }) { feed { id mime title } }
    }
  GQL

  SNAPSHOT = "mutation($url: String!) { snapshotUrl(input: { url: $url }) { run { id kind status selector } } }".freeze
  FETCH = "mutation($url: String!) { fetchUrl(input: { url: $url }) { run { id kind status selector } } }".freeze

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "add-#{SecureRandom.hex(4)}", name: "Adding")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "blobs", name: "Storage")
      @storage.make_default_storage!
    end

    connect!(@tenant)
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "a note becomes a text item named by its first line" do
    body = execute(NOTE, variables: { body: "# Pelicans\n\nRather a lot about them." })
    item = body.dig("data", "addNote", "feed")

    assert_equal MimeType::NOTE, item["mime"]
    assert_equal "Pelicans", item["title"]

    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      held = Feed.find(item["id"])

      assert_equal @storage.id, held.references.sole.resource_id
      assert_match(%r{\Anotes/\d{8}T\d{6}-pelicans\.md\z}, held.references.sole.locator_key)
    end
  end

  test "a note keeps the title it was given" do
    body = execute(NOTE, variables: { title: "Groceries", body: "milk\nbread" })

    assert_equal "Groceries", body.dig("data", "addNote", "feed", "title")
  end

  test "an empty note is refused" do
    body = execute(NOTE, variables: { body: "   \n  " })

    assert_nil body.dig("data", "addNote")
    assert_match(/needs something in it/, body.dig("errors", 0, "message"))
  end

  test "a note is queued for analysis so it becomes searchable" do
    assert_enqueued_jobs 1, only: AnalyzeFeedJob do
      execute(NOTE, variables: { body: "something worth finding later" })
    end
  end

  test "a note needs the write scope" do
    body = execute(NOTE, variables: { body: "no" }, scopes: %w[xixo:catalog:read])

    assert_nil body.dig("data", "addNote")
  end

  test "snapshotting an address opens a run against the browser resource" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    Tenant.switch(@tenant) { @web = Resource::Web.create!(key: "web", name: "The web") }

    assert_enqueued_jobs 1, only: SnapshotUrlJob do
      body = execute(SNAPSHOT, variables: { url: "https://example.com/a" })
      run = body.dig("data", "snapshotUrl", "run")

      assert_equal "snapshot", run["kind"]
      assert_equal "queued", run["status"]
      assert_equal "https://example.com/a", run.dig("selector", "url")
    end
  end

  test "snapshotting with nothing to render with says so" do
    body = execute(SNAPSHOT, variables: { url: "https://example.com/a" })

    assert_nil body.dig("data", "snapshotUrl")
    assert_match(/render a page/, body.dig("errors", 0, "message"))
  end

  test "an address that is not public is refused before a run is opened" do
    Tenant.switch(@tenant) { Resource::Web.create!(key: "web", name: "The web") }

    assert_no_enqueued_jobs only: SnapshotUrlJob do
      body = execute(SNAPSHOT, variables: { url: "http://169.254.169.254/latest/meta-data/" })

      assert_nil body.dig("data", "snapshotUrl")
      assert_match(/not a public address/, body.dig("errors", 0, "message"))
    end
  end

  test "fetching an address opens a run" do
    assert_enqueued_jobs 1, only: FetchUrlJob do
      body = execute(FETCH, variables: { url: "https://example.com/march.pdf" })

      assert_equal "fetch", body.dig("data", "fetchUrl", "run", "kind")
    end
  end

  test "fetching is refused where there is no storage to keep it in" do
    Tenant.switch(@tenant) { @storage.update!(archived_at: Time.current) }

    body = execute(FETCH, variables: { url: "https://example.com/march.pdf" })

    assert_nil body.dig("data", "fetchUrl")
    assert_match(/no storage to keep it in/, body.dig("errors", 0, "message"))
  end

  test "a fetched file lands in the catalog under the name it was served as" do
    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    server = FakeFeedServer.current
    server.reset!
    url = server.serve_body("/march.pdf", "a pretend pdf", content_type: "application/pdf")

    run = Tenant.switch(@tenant) { FetchUrlJob.start!(@tenant.id, url) }

    perform_enqueued_jobs(only: FetchUrlJob)
    perform_enqueued_jobs(only: AnalyzeFeedJob)

    Tenant.switch(@tenant) do
      item = Feed.find_by(title: "march.pdf")

      assert_equal "application/pdf", item.mime
      assert_equal "done", run.reload.status
      assert_equal url, item.references.sole.locator["source_url"]
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
           params: { query: query, variables: variables }.compact,
           headers: host_for(@tenant).merge(bearer(@tenant, scopes: scopes))

      response.parsed_body
    end
end
