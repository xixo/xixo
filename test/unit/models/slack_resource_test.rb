require "test_helper"

class SlackResourceTest < ActiveSupport::TestCase
  API = "https://slack.com/api".freeze

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "sl-#{SecureRandom.hex(4)}", name: "Slack")

    Tenant.switch(@tenant) do
      @resource = Resource::Slack.create!(
        key: "slack", name: "Workspace",
        details: {}, credentials: { "token" => "xoxb-secret" }
      )
    end

    stub_users
  end

  test "the stored type is slack and it syncs" do
    assert_equal "slack", @resource.type
    assert @resource.syncable?
  end

  test "check passes when the token names a workspace" do
    stub_ok("/auth.test", team: "Acme", user: "xixo")

    Tenant.switch(@tenant) { assert @resource.check! }
  end

  test "a refusal in the body is read, not the 200 it arrived with" do
    stub_ok("/auth.test", ok: false, error: "invalid_auth")

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Unusable) { @resource.check! }

      assert_match(/invalid_auth/, error.message)
    end
  end

  test "being rate limited is worth retrying and a bad token is not" do
    stub_ok("/auth.test", ok: false, error: "ratelimited")

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Failed) { @resource.check! }

      assert_not_kind_of Resource::Unusable, error
      assert_match(/another attempt/, error.message)
    end
  end

  test "only channels the bot is in are walked" do
    stub_channels([
      channel("C1", "general", member: true),
      channel("C2", "random", member: false)
    ])
    stub_history("C1", [ posted("1.0", "Morning") ])

    seen = []

    Tenant.switch(@tenant) { @resource.each_page { |batch, _| seen += batch } }

    assert_equal [ "C1" ], seen.map { |message| message["channel"] }
  end

  test "a named channel list narrows what is catalogued" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "channels" => "#general" })
    end

    stub_channels([ channel("C1", "general"), channel("C2", "random") ])
    stub_history("C1", [ posted("1.0", "Morning") ])

    seen = []

    Tenant.switch(@tenant) { @resource.each_page { |batch, _| seen += batch } }

    assert_equal [ "C1" ], seen.map { |message| message["channel"] }.uniq
  end

  test "a thread is one item, and a reply is not an item of its own" do
    stub_channels([ channel("C1", "general") ])
    stub_history("C1", [
      posted("1.0", "Widget jams", replies: 2, latest: "3.0"),
      posted("2.0", "Reproduced", thread_ts: "1.0"),
      { "type" => "message", "subtype" => "channel_join", "ts" => "4.0", "text" => "joined" }
    ])

    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal "C1/1.0", Feed.last.locator_key
      assert_equal "#general — Widget jams", Feed.last.title
    end
  end

  test "a new reply is a new version, so the thread is read again" do
    Tenant.switch(@tenant) do
      first = @resource.version_for("ts" => "1.0", "replies" => 1, "latest_reply" => "2.0")
      after = @resource.version_for("ts" => "1.0", "replies" => 2, "latest_reply" => "3.0")

      assert_not_equal first, after
    end
  end

  test "a sync resumes inside the channel it stopped in" do
    stub_channels([ channel("C1", "general"), channel("C2", "random") ])

    stub_request(:get, "#{API}/conversations.history")
      .with(query: hash_including({ "channel" => "C1", "cursor" => "half" }))
      .to_return(ok(messages: [ posted("9.0", "Later") ]))

    stub_history("C2", [ posted("1.0", "Elsewhere") ])

    seen = []

    Tenant.switch(@tenant) do
      @resource.each_page(cursor: "C1:half") { |batch, _| seen += batch }
    end

    assert_equal %w[C1 C2], seen.map { |message| message["channel"] }
    assert_not_requested :get, "#{API}/conversations.history",
                         query: hash_including({ "channel" => "C1", "cursor" => "" })
  end

  test "one thread looked up by its key is the thread a sync would have made" do
    stub_channels([ channel("C1", "general") ])
    stub_history("C1", [ posted("1.0", "Widget jams", replies: 2, latest: "3.0") ])

    Tenant.switch(@tenant) do
      synced = nil
      @resource.each_page { |batch, _| synced ||= batch.first }

      assert_kept_as_synced(@resource, synced, @resource.object_for("C1/1.0"))
      assert_kept_as_synced(@resource, synced, @resource.object_for("#general/1.0"))
    end

    assert_requested :get, "#{API}/conversations.history", times: 2,
                     query: hash_including({ "channel" => "C1", "latest" => "1.0", "oldest" => "1.0", "inclusive" => "true" })
  end

  test "keeping a thread catalogues it once, and a later sync finds the same one" do
    stub_channels([ channel("C1", "general") ])
    stub_history("C1", [ posted("1.0", "Widget jams") ])

    kept = Tenant.switch(@tenant) { @resource.command(:keep, key: "C1/1.0") }
    Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }

    Tenant.switch(@tenant) do
      assert_equal 1, Feed.files.count
      assert_equal kept["id"], feed_at("C1/1.0").id.to_s
    end
  end

  test "a reply, or a channel the bot is not in, is neither kept nor read" do
    stub_channels([ channel("C1", "general"), channel("C2", "secret", member: false) ])
    stub_history("C1", [ posted("2.0", "a reply", thread_ts: "1.0") ])

    Tenant.switch(@tenant) do
      assert_raises(Resource::Api::Gone) { @resource.command(:keep, key: "C1/2.0") }
      assert_raises(Resource::Api::Gone) { @resource.command(:keep, key: "C2/1.0") }
      assert_raises(Resource::Api::Gone) { @resource.command(:get, key: "C2/1.0") }
      assert_raises(ArgumentError) { @resource.command(:keep, key: "C1") }
      assert_equal 0, Feed.count
    end
  end

  test "downloading a thread is the conversation, with names rather than user ids" do
    stub_request(:get, "#{API}/conversations.replies")
      .with(query: hash_including({ "channel" => "C1", "ts" => "1.0" }))
      .to_return(ok(messages: [
        posted("1.0", "Widget jams", user: "U1"),
        posted("2.0", "Reproduced on 2.1", user: "U2")
      ]))

    text = Tenant.switch(@tenant) { @resource.download("channel" => "C1", "ts" => "1.0").read }

    assert_match(/ash: Widget jams/, text)
    assert_match(/bea: Reproduced on 2\.1/, text)
  end

  test "a thread longer than one page of replies says it read only the first" do
    stub_request(:get, "#{API}/conversations.replies")
      .with(query: hash_including({ "channel" => "C1", "ts" => "1.0" }))
      .to_return(ok(has_more: true, messages: [ posted("1.0", "Widget jams"), posted("2.0", "Again") ]))

    reference = Reference.new(resource: @resource, locator: { "channel" => "C1", "ts" => "1.0" })
    Tenant.switch(@tenant) { reference.download }

    assert_equal({ "replies" => "read the first 2 messages of the thread" }, reference.dropped)
  end

  test "people past the members it names are counted, once the list is full" do
    pages = Array.new(Resource::Slack::PEOPLE_PAGES) do |page|
      members = Array.new(Resource::Slack::PEOPLE) do |index|
        { "id" => "M#{page}-#{index}", "profile" => { "display_name" => "m#{page}-#{index}" } }
      end

      ok(members: members, response_metadata: { next_cursor: "more" })
    end
    stub_request(:get, "#{API}/users.list").with(query: hash_including({})).to_return(*pages)
    stub_request(:get, "#{API}/conversations.replies")
      .with(query: hash_including({ "channel" => "C1", "ts" => "1.0" }))
      .to_return(ok(messages: [
        posted("1.0", "Widget jams", user: "M0-1"),
        posted("2.0", "Me too", user: "U8"),
        posted("3.0", "And me", user: "U9"),
        posted("4.0", "Again", user: "U9")
      ]))

    reference = Reference.new(resource: @resource, locator: { "channel" => "C1", "ts" => "1.0" })
    text = Tenant.switch(@tenant) { reference.download.read }

    assert_match(/m0-1: Widget jams/, text)
    assert_match(/U8: Me too/, text)
    assert_equal({ "people" => "2 people shown by id, since only the first 1,000 members are named" },
                 reference.dropped)
  end

  test "an unknown speaker in a workspace small enough to name whole is not a truncation" do
    stub_request(:get, "#{API}/conversations.replies")
      .with(query: hash_including({}))
      .to_return(ok(messages: [ posted("1.0", "Hello", user: "B1") ]))

    reference = Reference.new(resource: @resource, locator: { "channel" => "C1", "ts" => "1.0" })
    Tenant.switch(@tenant) { reference.download }

    assert_equal({}, reference.dropped)
  end

  test "a file shared without a word is still catalogued by its name" do
    Tenant.switch(@tenant) do
      shared = { "channel" => "C1", "channel_name" => "general", "text" => "",
                 "files" => [ { "name" => "roadmap.pdf" } ] }

      assert_equal "#general — roadmap.pdf", @resource.title_for(shared)
    end
  end

  test "a thread that has gone is gone, not a broken resource" do
    stub_request(:get, "#{API}/conversations.replies")
      .with(query: hash_including({}))
      .to_return(ok(ok: false, error: "thread_not_found"))

    Tenant.switch(@tenant) do
      assert_raises(Resource::Api::Gone) { @resource.download("channel" => "C1", "ts" => "1.0") }
    end
  end

  test "nothing but slack.com is dialled" do
    Tenant.switch(@tenant) do
      assert_match(/is not Slack/,
                   assert_raises(Resource::Unusable) { @resource.api_get("https://evil.example.com/api/auth.test") }.message)
    end
  end

  private

    def ok(body)
      json_response({ ok: true }.merge(body))
    end

    def stub_ok(path, body = {})
      stub_request(:get, "#{API}#{path}").with(query: hash_including({})).to_return(ok(body))
      stub_request(:get, "#{API}#{path}").to_return(ok(body))
    end

    def channel(id, name, member: true)
      { "id" => id, "name" => name, "is_member" => member, "num_members" => 3 }
    end

    def posted(ts, text, user: "U1", thread_ts: nil, replies: 0, latest: nil)
      {
        "type" => "message", "ts" => ts, "text" => text, "user" => user,
        "thread_ts" => thread_ts, "reply_count" => replies, "latest_reply" => latest
      }.compact
    end

    def stub_channels(channels)
      stub_request(:get, "#{API}/conversations.list")
        .with(query: hash_including({}))
        .to_return(ok(channels: channels))
    end

    def stub_history(id, messages)
      stub_request(:get, "#{API}/conversations.history")
        .with(query: hash_including({ "channel" => id }))
        .to_return(ok(messages: messages))
    end

    def stub_users
      stub_request(:get, "#{API}/users.list")
        .with(query: hash_including({}))
        .to_return(ok(members: [
          { "id" => "U1", "profile" => { "display_name" => "ash" } },
          { "id" => "U2", "profile" => { "display_name" => "bea" } }
        ]))
    end
end
