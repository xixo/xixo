require "test_helper"
require_relative "../../support/fake_model_server"

class EmbeddingTest < ActiveSupport::TestCase
  MODELS = { "smart" => "llama3.1:8b", "embedding" => "nomic-embed-text" }.freeze

  setup do
    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves(MODELS.values).embeds(width: SearchIndex::VECTOR_DIMENSIONS)

    ENV["XIXO_INFERENCE_ORIGINS"] = @server.origin

    @tenant = Tenant.create!(subdomain: "vec-#{SecureRandom.hex(4)}", name: "Vectors")

    Tenant.switch(@tenant) do
      @brain = Resource::OpenaiCompatible.create!(
        key: "ollama", name: "Local models",
        details: { "base_url" => @server.base_url, "models" => MODELS }
      )
    end
  end

  teardown do
    ENV.delete("XIXO_INFERENCE_ORIGINS")
  end

  test "an item with no vector is swept up, embedded and re-indexed" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "application/pdf", title: "March invoice", locator_key: "invoices/march.pdf")

      assert_includes Feed.unembedded, item

      assert_equal 1, Embedding.sweep!

      item.reload

      assert_equal SearchIndex::VECTOR_DIMENSIONS, item.embedding.length
      assert item.embedded_at.present?
      assert_not_includes Feed.unembedded, item
    end
  end

  test "what changed while an item was being embedded is what reaches the index" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "text/plain", title: "Lease", locator_key: "lease.txt")
      brain = @brain.reload
      embed = brain.method(:embed)
      brain.define_singleton_method(:embed) do |texts|
        Feed.where(id: item.id).update_all(note: "Arrived while the vector was being made")
        embed.call(texts)
      end

      held_by = Embedding.method(:held)
      Embedding.define_singleton_method(:held) { brain }
      Embedding.sweep!
      Embedding.define_singleton_method(:held, held_by)
      SearchIndex.refresh!

      held = SearchIndex.client.get(index: SearchIndex.alias_for(@tenant), id: item.id)["_source"]

      assert_equal "Arrived while the vector was being made", held["note"]
    end
  end

  test "the sweep keeps going while there is a backlog, past one batch, within its time" do
    Tenant.switch(@tenant) do
      (Embedding::BATCH * 2 + 3).times { |index| create_feed(mime: "text/plain", title: "Note #{index}", locator_key: "notes/#{index}.txt") }
    end

    EmbedItemsJob.perform_now(budget: 1.minute)

    Tenant.switch(@tenant) { assert_empty Feed.unembedded }
  end

  test "the sweep stops at its time even with a backlog left" do
    Tenant.switch(@tenant) do
      (Embedding::BATCH + 3).times { |index| create_feed(mime: "text/plain", title: "Note #{index}", locator_key: "notes/#{index}.txt") }
    end

    EmbedItemsJob.perform_now(budget: 0.seconds)

    Tenant.switch(@tenant) { assert_equal Embedding::BATCH + 3, Feed.unembedded.count }
  end

  test "a stamp cleared over text that did not move is settled without asking the backend" do
    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "March invoice")

      Embedding.sweep!

      asked = @server.embedded.length

      Feed.update_all(embedded_at: nil)

      assert_equal 1, Embedding.sweep!

      assert_equal asked, @server.embedded.length,
                   "the text did not change, so it must not be embedded a second time"
      assert_empty Feed.unembedded.to_a
    end
  end

  test "a pass settling clears the stamp, so what it found reaches the vector" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "application/pdf", title: "scan-0001.pdf")

      Embedding.sweep!

      assert_empty Feed.unembedded.to_a

      summarized(item, "An invoice from Acme for $4,200.")

      assert_includes Feed.unembedded, item.reload
    end
  end

  test "a rename clears the stamp and a touch that cannot move the gist does not" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "application/pdf", title: "March invoice")

      Embedding.sweep!

      item.update!(origin: item.origin)

      assert_empty Feed.unembedded.to_a, "nothing in the gist changed"

      item.update!(title: "April invoice")

      assert_includes Feed.unembedded, item.reload
    end
  end

  test "naming a different embedding model re-embeds the catalogue rather than mixing two" do
    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "March invoice")

      Embedding.sweep!

      assert_empty Feed.unembedded.to_a

      @brain.update!(details: @brain.details.merge(
        "models" => MODELS.merge("embedding" => "mxbai-embed-large")
      ))

      assert_equal 1, Feed.unembedded.count,
                   "two models are two vector spaces, and half a catalogue in each answers neither"
    end
  end

  test "a model trained with prefixes gets them, one for what is kept and one for what is asked" do
    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "March invoice")

      Embedding.sweep!
      Embedding.query("what do I owe")

      assert(@server.embedded.first.start_with?("search_document: "))
      assert_equal "search_query: what do I owe", @server.embedded.last
    end
  end

  test "a model xixo does not know gets no prefix, and prefixes named on the backend win" do
    assert_empty Resource::OpenaiCompatible.prefixes_for("models" => { "embedding" => "text-embedding-3-small" })
    assert_equal({ "query" => "query: ", "document" => "passage: " },
                 Resource::OpenaiCompatible.prefixes_for("models" => { "embedding" => "multilingual-e5-large" }))
    assert_equal({ "query" => "Q: " },
                 Resource::OpenaiCompatible.prefixes_for("models" => { "embedding" => "nomic-embed-text" },
                                                         "embedding_prefixes" => { "query" => "Q: ", "document" => "" }))
  end

  test "vectors made before the prefixes were known are made again, once, feeds and passages alike" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "application/pdf", title: "March invoice")
      item.update_columns(embedding: [ 1.0 ], embedded_digest: "made the old way", embedded_at: Time.current)
      passage = Passage.create!(feed: item, position: 0, starts_at: 0, ends_at: 5, text: "March",
                                embedding: [ 1.0 ], embedded_at: Time.current)
      item.update_columns(passages_digest: Digest::SHA256.hexdigest(item.readable_text.to_s).first(32))

      Embedding.sweep!

      assert @brain.reload.vectors_current?
      assert_not_equal "made the old way", item.reload.embedded_digest
      assert_nil passage.reload.embedded_at

      Passage.embed!
      calls = @server.count_for("/v1/embeddings")
      Embedding.sweep!

      assert_equal calls, @server.count_for("/v1/embeddings"), "nothing is made twice"
    end
  end

  test "changing a prefix on the backend re-embeds the catalogue" do
    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "March invoice")
      Embedding.sweep!

      @brain.update!(details: @brain.details.merge("embedding_prefixes" => { "query" => "find: ", "document" => "doc: " }))

      assert_equal 1, Feed.unembedded.count
    end
  end

  test "changing something else about the backend leaves the catalogue alone" do
    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "March invoice")

      Embedding.sweep!

      @brain.update!(name: "Renamed")

      assert_empty Feed.unembedded.to_a
    end
  end

  test "text that changed is embedded again" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "application/pdf", title: "March invoice")

      Embedding.sweep!
      first = item.reload.embedded_digest

      item.update!(title: "April invoice")

      assert_includes Feed.unembedded, item

      Embedding.sweep!

      assert_not_equal first, item.reload.embedded_digest
    end
  end

  test "a whole page of items costs one call rather than one call each" do
    Tenant.switch(@tenant) do
      3.times { |n| Feed.create!(type: Feed::FILE, key: "bulk #{n}", title: "bulk #{n}") }

      assert_equal 3, Embedding.sweep!
      assert_equal 1, @server.count_for("/v1/embeddings")
    end
  end

  test "a backend serving no embedding model is not asked to stand in for one" do
    Tenant.switch(@tenant) do
      @brain.update!(details: @brain.details.merge("models" => { "default" => "llama3.1:8b" }))

      assert_nil Embedding.held, "a default model can write a summary, but it is not a vector space"

      create_feed(mime: "application/pdf", title: "March invoice")

      assert_equal 0, Embedding.sweep!
    end
  end

  test "the gist carries what analysis learned, not only the filename" do
    Tenant.switch(@tenant) do
      item = create_feed(mime: "application/pdf", title: "scan-0001.pdf")

      summarized(item, "An invoice from Acme for $4,200.", tags: %w[acme invoice])

      gist = Embedding.gist(item.reload)

      assert_match(/Acme/, gist)
      assert_match(/invoice/, gist)
    end
  end

  test "check refuses a model whose vectors are the wrong width for the index" do
    @server.embeds(width: 384)

    error = Tenant.switch(@tenant) { assert_raises(Resource::Unusable) { @brain.check! } }

    assert_match(/384/, error.message)
    assert_match(/#{SearchIndex::VECTOR_DIMENSIONS}/, error.message)
    assert_match(/XIXO_EMBEDDING_DIMENSIONS/, error.message)
  end

  test "check passes when the embedding model matches the index" do
    Tenant.switch(@tenant) { assert @brain.check! }
  end

  test "a search whose backend is asleep answers without a vector rather than failing" do
    dead = "http://127.0.0.1:1"
    ENV["XIXO_INFERENCE_ORIGINS"] = [ @server.origin, dead ].join(",")

    Tenant.switch(@tenant) do
      create_feed(mime: "application/pdf", title: "March invoice")

      @brain.update!(details: @brain.details.merge("base_url" => "#{dead}/v1"))

      assert_raises(Resource::Failed) { Embedding.sweep! }
      assert_nil Embedding.query("invoice"), "a search must not fail because the GPU is asleep"
    end
  end

  def summarized(feed, summary, tags: [])
    analysis = Analysis.open!(feed: feed, cause: "manual")
    analysis.write_step!("summary", { "result" => { "summary" => summary, "tags" => tags } })
    analysis.finished!
    analysis
  end
end
