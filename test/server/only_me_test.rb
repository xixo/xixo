require "test_helper"

class OnlyMeTest < ActionDispatch::IntegrationTest
  setup do
    SearchIndex.reset!
    PassageIndex.reset!

    @tenant = Tenant.create!(subdomain: "only-me-#{SecureRandom.hex(4)}", name: "Only me")
    connect!(@tenant)

    Tenant.switch(@tenant) do
      @shared = Resource::Database.create!(key: "household", name: "Household")
      @adas = Resource::Database.create!(key: "adas", name: "Ada's", owner_subject: "ada")

      @diary = keep(@adas, "diary.txt", "Ada's diary: the safe code is 4417.")
      @lease = keep(@shared, "lease.txt", "The lease runs to June. The safe is in the hall.")
      @page = Feed.create!(type: Feed::FILE, key: "diary-page", title: "diary-page", parent: @diary)
      Reference.record!(feed: @page, resource: Resource.internal!(:children), locator_key: "#{@diary.id}/0/0/page",
                        locator: { "key" => "#{@diary.id}/0/0/page" })
    end

    SearchIndex.refresh!
  end

  test "a file held only in someone's personal place is theirs to read, and a copy in a shared place is everyone's" do
    Tenant.switch(@tenant) do
      assert_equal [ "ada" ], @diary.reload.readers
      assert_equal [ "ada" ], @page.reload.readers
      assert_nil @lease.reload.readers

      Reference.record!(feed: @diary, resource: @shared, locator_key: "diary.txt", locator: { "key" => "diary.txt" })

      assert_nil @diary.reload.readers
      assert_nil @page.reload.readers
    end
  end

  test "nobody else finds, opens, or counts what is only someone's" do
    assert_equal [ @lease.id.to_s ], ids(graphql("bob", %({ search(query: "safe") { nodes { id } } })), "search")
    assert_includes ids(graphql("ada", %({ search(query: "safe") { nodes { id } } })), "search"), @diary.id.to_s

    assert_nil graphql("bob", %({ feed(id: "#{@diary.id}") { id } })).dig("data", "feed")
    assert_equal @diary.id.to_s, graphql("ada", %({ feed(id: "#{@diary.id}") { id } })).dig("data", "feed", "id")

    listed = ids(graphql("bob", %({ feeds(type: "#{Feed::FILE}") { nodes { id } } })), "feeds")
    assert_equal [ @lease.id.to_s ], listed

    refused = graphql("bob", %(mutation { renameFeed(input: { id: "#{@diary.id}", title: "mine" }) { feed { id } } }))
    assert_match(/no feed with id/, refused.dig("errors", 0, "message"))
  end

  test "the tools refuse what is only someone else's" do
    as("bob") do
      found = JSON.parse(Tool::Search.call(server_context: {}, query: "safe").content.first[:text])
      read = Tool::Feeds.call(server_context: {}, id: @diary.id.to_s)

      assert_equal [ @lease.id.to_s ], found["feeds"].pluck("id")
      assert read.error?
      assert_match(/no feed with id/, read.content.first[:text])
    end

    as("ada") { assert_not Tool::Feeds.call(server_context: {}, id: @diary.id.to_s).error? }
  end

  test "an answer for one person never reads another's personal file" do
    bobs = as("bob") { Evidence.new("what is the safe code").feeds }
    adas = as("ada") { Evidence.new("what is the safe code").feeds }

    assert_not_includes bobs, @diary
    assert_includes adas, @diary
  end

  test "a run nobody asked for reads only what everyone can" do
    Tenant.switch(@tenant) do
      Current.grant = @lease.grant

      assert_not_includes Evidence.new("what is the safe code").feeds, @diary
    ensure
      Current.grant = nil
    end
  end

  test "what a run writes after reading someone's personal file is theirs alone" do
    Tenant.switch(@tenant) do
      Current.grant = @lease.grant(speaking_for: "ada")
      Current.acting_for = @lease.id
      Current.confined_to = Concurrent::Set.new([ @lease.id ])

      Tool::Feeds.call(server_context: {}, id: @diary.id.to_s)
      made = JSON.parse(Tool::Feeds.call(server_context: {}, do: "create", title: "Safe code").content.first[:text])

      assert_equal [ "ada" ], Feed.find(made["id"]).readers
    ensure
      Current.reset
    end
  end

  test "an answer that read someone's personal file is kept to them" do
    Tenant.switch(@tenant) do
      question = Feed.create!(type: Feed::NOTE, key: "what is the safe code?")
      grant = question.grant(speaking_for: "ada")
      Current.grant = grant

      Evidence.new("what is the safe code")
      grant.keep_to_reader!(question)

      assert_equal [ "ada" ], question.reload.readers
    ensure
      Current.reset
    end
  end

  test "a run that read only what everyone can leaves what it writes for everyone" do
    Tenant.switch(@tenant) do
      question = Feed.create!(type: Feed::NOTE, key: "when does the lease run to?")
      grant = question.grant(speaking_for: "bob")
      Current.grant = grant

      Evidence.new("when does the lease run to")
      grant.keep_to_reader!(question)

      assert_nil question.reload.readers
    ensure
      Current.reset
    end
  end

  test "nobody else downloads its bytes" do
    reference = Tenant.switch(@tenant) { @diary.references.first }

    get "/references/#{reference.id}/content", headers: headers("bob")
    assert_response :not_found

    get "/references/#{reference.id}/content", headers: headers("ada")
    assert_response :success
  end

  test "an export takes only what the person asking can read" do
    graphql("bob", %(mutation { exportFeeds(input: { destinationId: "#{@shared.id}" }) { run { id } } }))
    run = Tenant.switch(@tenant) { Run.where(kind: "export").last }

    assert_equal "bob", run.selector["reader"]

    Tenant.switch(@tenant) do
      selected = Feed.referenced.readable_to(run.selector["reader"]).matching(run.selector)

      assert_not_includes selected, @diary
      assert_includes selected, @lease
    end
  end

  private

    def keep(resource, key, text)
      resource.upload(key, text)
      feed = Feed.create!(type: Feed::FILE, key: key, title: key)
      Reference.record!(feed: feed, resource: resource, locator_key: key, locator: { "key" => key }, mime: "text/plain")
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analysis.write_step!("text", { "result" => text })
      analysis.finished!
      feed.reload
    end

    def headers(subject)
      token = issuer.mint(subdomain: @tenant.subdomain, subject: subject, scopes: Grant::SCOPES,
                          audience: "http://#{@tenant.subdomain}.xixo.test/mcp")

      { "HOST" => "#{@tenant.subdomain}.xixo.test", "Authorization" => "Bearer #{token}" }
    end

    def graphql(subject, query)
      post "/graphql", params: { query: query }, headers: headers(subject)

      response.parsed_body
    end

    def ids(body, field)
      body.dig("data", field, "nodes").to_a.pluck("id")
    end

    def as(subject)
      Tenant.switch(@tenant) do
        Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => subject, "scope" => Grant::SCOPES.join(" ")))
        yield
      ensure
        Current.grant = nil
      end
    end
end
