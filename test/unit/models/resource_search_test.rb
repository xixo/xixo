require "test_helper"

class ResourceSearchTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "srch-#{SecureRandom.hex(4)}", name: "Search")
  end

  def engine(**details)
    Tenant.switch(@tenant) do
      Resource::Search.create!(
        key: "web-search-#{SecureRandom.hex(4)}", name: "Web search",
        details: { "provider" => "exa" }.merge(details),
        credentials: { "api_key" => "sk-test" }
      )
    end
  end

  test "a provider nobody adapts is refused" do
    Tenant.switch(@tenant) do
      found = Resource::Search.new(key: "nope", details: { "provider" => "askjeeves" },
                                   credentials: { "api_key" => "x" })

      assert_not found.valid?
      assert_match(/must name a provider/, found.errors.full_messages.join)
    end
  end

  test "a search resource without a key cannot answer, so it is refused" do
    Tenant.switch(@tenant) do
      found = Resource::Search.new(key: "nope", details: { "provider" => "exa" })

      assert_not found.valid?
      assert_match(/api_key/, found.errors.full_messages.join)
    end
  end

  test "each provider falls back to its own endpoint until one is named" do
    Tenant.switch(@tenant) do
      assert_equal "https://api.exa.ai/search", engine.endpoint
      assert_equal "https://elsewhere.test/s", engine(**{ "endpoint" => "https://elsewhere.test/s" }).endpoint
    end
  end

  test "it searches, and is the tenant's search capability" do
    stub_request(:post, "https://api.exa.ai/search")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { results: [
                   { title: "  A page  ", url: "https://example.test/a", text: "Some\n  text",
                     publishedDate: "2026-01-02" },
                   { title: "No address", text: "dropped" }
                 ] }.to_json)

    Tenant.switch(@tenant) do
      found = engine
      results = found.search("anything")

      assert_equal [ :search ], found.capabilities
      assert_includes Resource.capable_of(:search), found
      assert_equal 1, results.size
      assert_equal({ title: "A page", url: "https://example.test/a", snippet: "Some text",
                     published_at: "2026-01-02" }, results.first)
    end
  end

  test "brave answers a different shape and normalises to the same one" do
    stub_request(:get, "https://api.search.brave.com/res/v1/web/search")
      .with(query: { q: "anything", count: "3" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { web: { results: [
                   { title: "B", url: "https://example.test/b", description: "why" }
                 ] } }.to_json)

    Tenant.switch(@tenant) do
      results = engine(**{ "provider" => "brave" }).search("anything", limit: 3)

      assert_equal "https://example.test/b", results.first[:url]
      assert_equal "why", results.first[:snippet]
    end
  end

  test "a limit is clamped rather than trusted" do
    stub_request(:post, "https://api.exa.ai/search")
      .with(body: hash_including({ "numResults" => Resource::Search::MAX_LIMIT }))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { results: [] }.to_json)

    Tenant.switch(@tenant) { assert_empty engine.search("anything", limit: 500) }
  end

  test "an empty query is refused before anything is asked" do
    Tenant.switch(@tenant) do
      assert_raises(ArgumentError) { engine.search("   ") }
    end
  end

  test "a provider that does not answer with JSON is unusable rather than silently empty" do
    stub_request(:post, "https://api.exa.ai/search")
      .to_return(status: 200, body: "<html>rate limited</html>")

    Tenant.switch(@tenant) do
      assert_raises(Resource::Unusable) { engine.search("anything") }
    end
  end

  test "a self-hosted engine needs no key, but does need an address" do
    Tenant.switch(@tenant) do
      nowhere = Resource::Search.new(key: "sx", details: { "provider" => "searxng" })

      assert_not nowhere.valid?
      assert_match(/must name an endpoint/, nowhere.errors.full_messages.join)

      somewhere = Resource::Search.new(key: "sx", details: { "provider" => "searxng",
                                                            "endpoint" => "https://s.example.com" })

      assert somewhere.valid?, somewhere.errors.full_messages.join
    end
  end

  test "a searxng base url grows the search path it answers on" do
    Tenant.switch(@tenant) do
      base = engine(**{ "provider" => "searxng", "endpoint" => "https://s.example.com" })
      full = engine(**{ "provider" => "searxng", "endpoint" => "https://s.example.com/search" })

      assert_equal "https://s.example.com/search", base.endpoint
      assert_equal "https://s.example.com/search", full.endpoint
    end
  end

  test "searxng is asked over a plain query, with no key on the wire" do
    stub_request(:get, "https://example.com/search")
      .with(query: { q: "anything", format: "json" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { results: [ { url: "https://example.test/c", title: "C",
                                      content: "found it" } ] }.to_json)

    Tenant.switch(@tenant) do
      results = engine(**{ "provider" => "searxng", "endpoint" => "https://example.com" }).search("anything")

      assert_equal "found it", results.first[:snippet]
    end
  end

  test "a private engine answers only when its origin was named" do
    Tenant.switch(@tenant) do
      inside = engine(**{ "provider" => "searxng", "endpoint" => "http://127.0.0.1:8888/search" })

      assert_raises(PublicFetch::Blocked) { inside.search("anything") }

      stub_request(:get, "http://127.0.0.1:8888/search")
        .with(query: { q: "anything", format: "json" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { results: [] }.to_json)

      with_origins("http://127.0.0.1:8888") { assert_empty inside.search("anything") }
    end
  end

  test "a private address is blocked, so a named endpoint cannot reach inside" do
    Tenant.switch(@tenant) do
      inside = engine(**{ "endpoint" => "http://127.0.0.1:9200/search" })

      assert_raises(PublicFetch::Blocked) { inside.search("anything") }
    end
  end

  private

    def with_origins(value)
      previous = ENV["XIXO_SEARCH_ORIGINS"]
      ENV["XIXO_SEARCH_ORIGINS"] = value
      yield
    ensure
      ENV["XIXO_SEARCH_ORIGINS"] = previous
    end
end
