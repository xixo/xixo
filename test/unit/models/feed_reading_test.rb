require "test_helper"
require_relative "../../support/fake_model_server"

class FeedReadingTest < ActiveSupport::TestCase
  LONG = (1..3_000).map { |line| line == 2_500 ? "Clause 2500 sets out severance on dismissal." : "Clause #{line} says the same thing again." }.join("\n")

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

  test "words looked for in a long text come back as the passages that mention them, wherever they are" do
    found = opened(find: "Severance dismissal")

    assert_equal 1, found["found"]
    assert_equal 1, found["passages"].size
    assert_equal "words", found["passages"].first["matched_by"]
    assert_includes found["passages"].first["text"], "sets out severance on dismissal"
    assert_operator found["passages"].first["from"], :>, Tool::Feeds::EXCERPT
    assert_nil found["text"]
  end

  test "a question finds the passage that means it, though they share no word" do
    server = FakeModelServer.current
    server.reset!.serves("nomic-embed-text").embeds(width: SearchIndex::VECTOR_DIMENSIONS)
    ENV["URIS_INFERENCE_ORIGINS"] = server.origin
    PassageIndex.reset!
    toward = Array.new(SearchIndex::VECTOR_DIMENSIONS, 0.0).tap { |vector| vector[11] = 1.0 }
    server.embeds_as("what if the roof leaks", toward)

    Tenant.switch(@tenant) do
      Resource::OpenaiCompatible.create!(
        key: "ollama", details: { "base_url" => server.base_url, "models" => { "embedding" => "nomic-embed-text" } }
      )
      Passage.cut!(@feed.reload)
      wanted = Passage.where(feed: @feed).find_by!(position: 40)
      wanted.update_columns(embedding: toward, embedded_at: Time.current)
      PassageIndex.index_all([ wanted ])
      PassageIndex.refresh!

      found = opened(find: "what if the roof leaks")["passages"]

      assert_includes found.map { |passage| [ passage["from"], passage["matched_by"] ] }, [ wanted.starts_at, "meaning" ]
    end
  ensure
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end
end
