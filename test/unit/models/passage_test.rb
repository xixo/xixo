require "test_helper"
require_relative "../../support/fake_model_server"

class PassageTest < ActiveSupport::TestCase
  WIDTH = SearchIndex::VECTOR_DIMENSIONS
  MANUAL = (1..40).map { |number| "Step #{number} of the shed manual covers one more plank and one more nail. " * 3 }
                  .join("\n\n")

  setup do
    SearchIndex.reset!
    PassageIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves("nomic-embed-text").embeds(width: WIDTH)
    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "pass-#{SecureRandom.hex(4)}", name: "Passages")
    @other = Tenant.create!(subdomain: "pass-#{SecureRandom.hex(4)}", name: "Elsewhere")

    [ @tenant, @other ].each do |tenant|
      Tenant.switch(tenant) do
        Resource::OpenaiCompatible.create!(
          key: "ollama", details: { "base_url" => @server.base_url, "models" => { "embedding" => "nomic-embed-text" } }
        )
      end
    end
  end

  teardown { ENV.delete("URIS_INFERENCE_ORIGINS") }

  def pointing(at)
    Array.new(WIDTH, 0.0).tap { |vector| vector[at] = 1.0 }
  end

  def manual_in(tenant, body = MANUAL)
    Tenant.switch(tenant) do
      Feed.create!(type: Feed::NOTE, key: "Shed manual", title: "Shed manual").tap do |feed|
        Analysis.create!(feed: feed, cause: "manual", status: "done", finished_at: Time.current,
                         steps: { "text" => { "result" => body, "finished_at" => Time.current.iso8601 } })
      end
    end
  end

  test "a text short enough to be one passage is not cut" do
    assert_empty Passage.split("A short note.")
    assert_empty Passage.split("x" * Passage::SIZE)
  end

  test "a long text is cut into passages that cover it, overlap, and end where a paragraph does" do
    spans = Passage.split(MANUAL)

    assert_operator spans.size, :>, 5
    assert_equal 0, spans.first.first
    assert_equal MANUAL.length, spans.last.last
    spans.each { |start, finish| assert_operator finish - start, :<=, Passage::SIZE }
    spans.each_cons(2) { |(_, finish), (start, _)| assert_operator start, :<, finish, "passages overlap" }
    spans[0...-1].each { |_, finish| assert_equal "\n\n", MANUAL[finish - 2, 2], "a passage ends at a paragraph" }
  end

  test "a text with nowhere to break is still cut, and the cutting ends" do
    spans = Passage.split("x" * (Passage::SIZE * 3))

    assert_operator spans.size, :>=, 3
    assert_equal Passage::SIZE * 3, spans.last.last
  end

  test "cutting is done once for a text, again when the text changes, and never for another tenant" do
    feed = manual_in(@tenant)

    Tenant.switch(@tenant) do
      assert Passage.cut!(feed.reload)
      held = Passage.where(feed: feed).count
      assert_operator held, :>, 5
      assert_not Passage.cut!(feed.reload), "the same text is not cut again"

      feed.analysis.write_step!("text", feed.analysis.step("text").merge("result" => MANUAL.first(Passage::SIZE * 2)))
      assert Passage.cut!(feed.reload)
      assert_operator Passage.where(feed: feed).count, :<, held
    end

    Tenant.switch(@other) { assert_equal 0, Passage.count }
  end

  test "passages are embedded with their document's title and found by meaning within one tenant" do
    feed = manual_in(@tenant)
    elsewhere = manual_in(@other)

    Tenant.switch(@tenant) { Passage.sweep! }
    Tenant.switch(@other) { Passage.sweep! }
    PassageIndex.refresh!

    assert(@server.embedded.all? { |text| text.start_with?("search_document: Shed manual\n") })

    Tenant.switch(@tenant) do
      wanted = Passage.where(feed: feed).find_by!(position: 3)
      wanted.update_columns(embedding: pointing(7))
      PassageIndex.index_all([ wanted ])
      PassageIndex.refresh!

      hits = PassageIndex.nearest(pointing(7), tenant: @tenant, limit: 5)

      assert_equal [ [ feed.id, wanted.starts_at ] ], hits.map { |hit| [ hit.feed_id, hit.starts_at ] }
      assert_empty PassageIndex.nearest(pointing(7), tenant: @tenant, limit: 5, feed_id: elsewhere.id)
    end

    Tenant.switch(@other) { assert_empty PassageIndex.nearest(pointing(7), tenant: @other, limit: 5) }
  end

  test "a document forgotten takes its passages with it" do
    feed = manual_in(@tenant)
    Tenant.switch(@tenant) { Passage.sweep! }
    PassageIndex.refresh!

    Tenant.switch(@tenant) { feed.reload.destroy! }
    PassageIndex.refresh!

    Tenant.switch(@tenant) { assert_equal 0, Passage.count }
    count = PassageIndex.client.count(index: PassageIndex.name, body: { query: { term: { feed_id: feed.id } } })["count"]
    assert_equal 0, count
  end

  test "a passage deep in a long document brings the document into search, and the result carries it" do
    feed = manual_in(@tenant)
    @server.embeds_as("search_query: what if the roof leaks", pointing(21))

    Tenant.switch(@tenant) do
      Passage.cut!(feed.reload)
      deep = Passage.where(feed: feed).order(:position).last
      deep.update_columns(embedding: pointing(21), embedded_at: Time.current)
      PassageIndex.index_all([ deep ])
      SearchIndex.index(feed.reload)
      [ PassageIndex, SearchIndex ].each(&:refresh!)

      assert_includes Feed.search("what if the roof leaks").map(&:id), feed.id

      Current.grant = Grant.new(tenant: @tenant, claims: Masks::Client::Claims.new("sub" => "someone", "scope" => Grant::SCOPES.join(" ")))
      reply = JSON.parse(Tool::Search.call(server_context: {}, query: "what if the roof leaks").content.first[:text])
      found = reply["feeds"].find { |held| held["id"] == feed.id.to_s }

      assert_equal deep.starts_at, found.dig("passage", "from")
      assert_includes found.dig("passage", "text"), "shed manual"
    ensure
      Current.grant = nil
    end
  end
end
