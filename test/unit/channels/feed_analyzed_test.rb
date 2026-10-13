require "test_helper"

class FeedAnalyzedTest < ActionCable::Channel::TestCase
  tests GraphqlChannel

  EVERY_THING = <<~GRAPHQL
    subscription FeedAnalyzed { feedAnalyzed { feed { id mime title } } }
  GRAPHQL

  ONE_THING = <<~GRAPHQL
    subscription FeedAnalyzed($id: ID!) { feedAnalyzed(id: $id) { feed { id title } } }
  GRAPHQL

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "sub-#{SecureRandom.hex(4)}", name: "Subscribed")
    @other = Tenant.create!(subdomain: "sub-#{SecureRandom.hex(4)}", name: "Elsewhere")

    Tenant.switch(@tenant) do
      @storage = Resource::Database.create!(key: "database", name: "Storage")
      @feed = feed_on("notes.txt", "the notes")
      @unwatched = feed_on("other.txt", "other notes")
    end
  end

  test "subscribing listens on an event stream of its own" do
    subscribe_as(@tenant, EVERY_THING)

    assert_not_nil event_stream
  end

  test "finishing an analysis reaches a tenant-wide subscriber's stream" do
    subscribe_as(@tenant, EVERY_THING)
    stream = event_stream

    assert_broadcasts(stream, 1) { analyze(@feed) }
    assert_includes broadcasts(stream).last, @feed.to_gid_param
  end

  test "a second analysis is a second event" do
    subscribe_as(@tenant, EVERY_THING)
    stream = event_stream

    assert_broadcasts(stream, 2) do
      analyze(@feed)
      analyze(@unwatched)
    end
  end

  test "watching one feed hears that feed and not the others" do
    subscribe_as(@tenant, ONE_THING, id: @feed.id.to_s)
    stream = event_stream

    assert_no_broadcasts(stream) { analyze(@unwatched) }
    assert_broadcasts(stream, 1) { analyze(@feed) }
  end

  test "another tenant's subscriber is on a different stream entirely" do
    subscribe_as(@tenant, EVERY_THING)
    mine = event_stream

    subscribe_as(@other, EVERY_THING)
    theirs = event_stream

    assert_not_equal mine, theirs
    assert_no_broadcasts(theirs) { analyze(@feed) }
  end

  test "a delivery loads the changed record inside the subscriber's tenant" do
    message = GraphQL::Subscriptions::Serialize.dump(@feed)

    assert_equal @feed, XixoSchema.subscriptions.send(:load_action_cable_message, message, { tenant: @tenant })
  end

  private

    def analyze(feed)
      Tenant.switch(@tenant) do
        Analyzer.for(feed, analysis: Analysis.open!(feed: feed, cause: "manual")).run
      end
    end

    def feed_on(key, body)
      @storage.upload(key, body)

      Reference.discover!(resource: @storage, locator: { "key" => key },
                          locator_key: key, mime: "text/plain", title: key).feed
    end

    def subscribe_as(tenant, query, scopes: Grant::SCOPES, **variables)
      stub_connection(tenant: tenant, grant: grant_for(tenant, scopes))
      subscribe
      perform :execute, "query" => query, "variables" => variables.stringify_keys
    end

    def grant_for(tenant, scopes)
      Grant.new(
        tenant: tenant,
        claims: Masks::Client::Claims.new(
          "sub" => "test", "scope" => Array(scopes).join(" "),
          "tenant" => { "subdomain" => tenant.subdomain },
          "exp" => 1.hour.from_now.to_i
        )
      )
    end

    def event_stream
      subscription.streams.find { |stream| stream.start_with?("graphql-event:") }
    end
end
