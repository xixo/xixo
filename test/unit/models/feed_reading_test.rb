require "test_helper"

class FeedReadingTest < ActiveSupport::TestCase
  LONG = (1..3_000).map { |line| "Clause #{line} says the same thing again." }.join("\n")

  setup do
    @tenant = Tenant.create!(subdomain: "read-#{SecureRandom.hex(4)}", name: "Reading")

    Tenant.switch(@tenant) do
      @feed = Feed.create!(type: Feed::NOTE, key: "agreement", title: "Agreement")
      Analysis.create!(feed: @feed, cause: "manual", status: "done", finished_at: Time.current,
                       steps: { "text" => { "result" => LONG, "finished_at" => Time.current.iso8601 } })
      Current.grant = Grant.new(tenant: @tenant,
                                claims: Masks::Client::Claims.new("sub" => "someone", "scope" => Grant::SCOPES.join(" ")))
    end
  end

  teardown { Current.grant = nil }

  def opened(**arguments)
    Tenant.switch(@tenant) do
      reply = Tool::Feeds.call(server_context: {}, id: @feed.id.to_s, **arguments)
      raise reply.content.first[:text] if reply.error?

      JSON.parse(reply.content.first[:text])
    end
  end

  test "a long text comes a part at a time, and each part says where the next begins" do
    first = opened

    assert_equal Tool::Feeds::EXCERPT, first["text"].length
    assert_equal({ "id" => @feed.id.to_s, "from" => Tool::Feeds::EXCERPT }, first.dig("text_part", "next"))
    assert_equal LONG.length, first.dig("text_part", "of")

    read = first["text"]
    part = first
    while (following = part.dig("text_part", "next"))
      part = opened(from: following["from"])
      read += part["text"]
    end

    assert_equal LONG, read
    assert_nil part.dig("text_part", "next")
  end

  test "the text is not handed over a second time inside the steps" do
    step = opened["steps"]["text"]

    assert_operator step.length, :<, 1_000
    assert_match(/#{LONG.length} characters in all/, step)
  end
end
