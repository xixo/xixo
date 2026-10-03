require "test_helper"

class FeedTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "feed-#{SecureRandom.hex(4)}", name: "Feeds")
  end

  def address(key)
    Feed.new(type: Feed::ADDRESS, key: key)
  end

  test "an address the application already answers to is refused" do
    Tenant.switch(@tenant) do
      Feed::RESERVED.first(4).each do |taken|
        feed = address("/#{taken}")

        assert_not feed.valid?, "#{taken} should be refused"
        assert_match(/path uris already answers to/, feed.errors[:key].first)
      end
    end
  end

  test "an address is a slash, then letters, numbers and dashes" do
    Tenant.switch(@tenant) do
      assert address("/buy-2024").valid?

      [ "/Buy", "/buy things", "/buy/now", "/-buy", "buy", "/", "" ].each do |bad|
        assert_not address(bad).valid?, "#{bad.inspect} should be refused"
      end
    end
  end

  test "an address is unique per tenant and free in another" do
    other = Tenant.create!(subdomain: "feed-#{SecureRandom.hex(4)}", name: "Other")

    Tenant.switch(@tenant) { Feed.create!(type: Feed::ADDRESS, key: "/buy") }
    Tenant.switch(@tenant) { assert_not address("/buy").valid? }
    Tenant.switch(other) { assert address("/buy").valid? }
  end

  test "a file is not a singleton, so two of them may share a key" do
    Tenant.switch(@tenant) do
      Feed.create!(type: Feed::FILE, key: "invoice.pdf", title: "One")

      assert Feed.new(type: Feed::FILE, key: "invoice.pdf", title: "Another").valid?
    end
  end

  test "a schedule opens an analysis of the feed it runs" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::ADDRESS, key: "/buy")
      schedule = feed.create_schedule!(prompt: "find things")

      analysis = schedule.run!

      assert_equal feed, analysis.feed
      assert_equal "schedule", analysis.cause
      assert analysis.open?
      assert_in_delta Time.current, schedule.reload.ran_at, 5
    end
  end

  test "only an address carries a schedule, since nothing else runs itself" do
    Tenant.switch(@tenant) do
      file = Feed.create!(type: Feed::FILE, key: "invoice.pdf", title: "An invoice")

      assert_not Schedule.new(feed: file, prompt: "x").valid?
    end
  end

  test "a feed acts as itself rather than borrowing anyone's token" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::ADDRESS, key: "/buy")

      assert_equal "feed:/buy", feed.grant.subject
      assert_equal @tenant, feed.grant.tenant
      assert_equal Feed::AGENT_SCOPES.sort, feed.grant.scopes.sort
      assert_not feed.grant.permits?("uris:settings:admin")
    end
  end

  test "turns fall back to the default" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::ADDRESS, key: "/buy")

      assert_equal Schedule::TURNS, Schedule.new(feed: feed, prompt: "x").turns_allowed
      assert_equal 2, Schedule.new(feed: feed, prompt: "x", turns: 2).turns_allowed
    end
  end

  test "every path the application answers to is reserved" do
    spoken = Rails.application.routes.routes.filter_map do |route|
      route.path.spec.to_s[%r{\A/([a-z0-9-]+)}, 1]
    end.uniq

    assert_empty spoken - Feed::RESERVED,
                 "these are routes an address could shadow"
  end

  test "what a feed holds is what it is connected to, and nothing else" do
    Tenant.switch(@tenant) do
      feed = Feed.create!(type: Feed::ADDRESS, key: "/buy")
      kept = Feed.create!(type: Feed::FILE, key: "kept", title: "kept")
      loose = Feed.create!(type: Feed::FILE, key: "loose", title: "loose")

      feed.connect!(kept)

      assert_equal [ kept ], feed.connected.to_a
      assert_not_includes feed.connected, loose
    end
  end

  test "a connection is symmetric, and stored once whichever way it is made" do
    Tenant.switch(@tenant) do
      one = Feed.create!(type: Feed::FILE, key: "one", title: "one")
      other = Feed.create!(type: Feed::FILE, key: "two", title: "two")

      one.connect!(other)
      other.connect!(one)

      assert_equal 1, Edge.touching(one.id).count
      assert_equal [ other ], one.connected.to_a
      assert_equal [ one ], other.connected.to_a
    end
  end

  test "an address that holds nothing is empty rather than everything" do
    Tenant.switch(@tenant) do
      Feed.create!(type: Feed::FILE, key: "loose", title: "loose")

      assert_empty Feed.create!(type: Feed::ADDRESS, key: "/nothing-here").connected
    end
  end
end
