require "test_helper"
require_relative "../../support/fake_model_server"

class SemanticSearchTest < ActiveSupport::TestCase
  MODELS = { "embedding" => "nomic-embed-text" }.freeze
  WIDTH = SearchIndex::VECTOR_DIMENSIONS

  setup do
    SearchIndex.reset!

    @server = FakeModelServer.current
    @server.reset!.serves(MODELS.values).embeds(width: WIDTH)

    ENV["URIS_INFERENCE_ORIGINS"] = @server.origin

    @demo = Tenant.create!(subdomain: "sem-#{SecureRandom.hex(4)}", name: "Demo")
    @acme = Tenant.create!(subdomain: "sem-#{SecureRandom.hex(4)}", name: "Acme")

    [ @demo, @acme ].each do |tenant|
      Tenant.switch(tenant) do
        Resource::OpenaiCompatible.create!(
          key: "ollama", details: { "base_url" => @server.base_url, "models" => MODELS }
        )
      end
    end
  end

  teardown do
    ENV.delete("URIS_INFERENCE_ORIGINS")
  end

  test "a query finds an item that shares no word with it" do
    @server.embeds_as("search_query: what did the vet say", near)

    Tenant.switch(@demo) do
      semantic = create_feed(mime: "application/pdf", title: "Rosie annual checkup")

      semantic.update_columns(embedding: near, embedded_digest: "held", embedded_at: Time.current)
      SearchIndex.index(semantic.reload)
      SearchIndex.refresh!

      assert_empty SearchIndex.lexical("what did the vet say", tenant: @demo,
                                       limit: 50, from: 0)[:ids],
                   "no word overlaps, so the lexical side has nothing to offer"

      assert_equal [ semantic.id ], Feed.search("what did the vet say").map(&:id)
    end
  end

  test "a lexical hit the vector missed is kept, not replaced" do
    @server.embeds_as("search_query: invoice", near)

    Tenant.switch(@demo) do
      lexical = create_feed(mime: "application/pdf", title: "March invoice")
      semantic = create_feed(mime: "application/pdf", title: "unrelated")

      semantic.update_columns(embedding: near, embedded_digest: "held", embedded_at: Time.current)
      SearchIndex.index(semantic.reload)
      SearchIndex.refresh!

      found = Feed.search("invoice").map(&:id)

      assert_includes found, lexical.id
      assert_includes found, semantic.id
    end
  end

  test "a neighbour that is only the nearest of strangers is not a match" do
    @server.embeds_as("search_query: pelican", near)

    Tenant.switch(@demo) do
      stranger = create_feed(mime: "application/pdf", title: "certificate")
      stranger.update_columns(embedding: far, embedded_digest: "held", embedded_at: Time.current)
      SearchIndex.index(stranger.reload)
      SearchIndex.refresh!

      assert_empty Feed.search("pelican").map(&:id)
    end
  end

  test "neighbours well behind the nearest one are left to the lexical side" do
    Tenant.switch(@demo) do
      close = create_feed(mime: "application/pdf", title: "one")
      behind = create_feed(mime: "application/pdf", title: "two")
      close.update_columns(embedding: near, embedded_digest: "held", embedded_at: Time.current)
      behind.update_columns(embedding: leaning, embedded_digest: "held", embedded_at: Time.current)
      [ close, behind ].each { |feed| SearchIndex.index(feed.reload) }
      SearchIndex.refresh!

      assert_equal [ close.id ], SearchIndex.nearest(near, tenant: @demo, limit: 50)
    end
  end

  test "a lexical match still leads when nothing is nearer" do
    Tenant.switch(@demo) do
      match = create_feed(mime: "application/pdf", title: "March invoice")
      create_feed(mime: "application/pdf", title: "Beach photo")

      Embedding.sweep!
      SearchIndex.refresh!

      assert_equal match.id, Feed.search("March invoice").first.id
    end
  end

  test "a vector query is filtered by tenant inside the query, not only by the alias" do
    Tenant.switch(@acme) do
      hidden = create_feed(mime: "application/pdf", title: "Acme secret")
      hidden.update_columns(embedding: near, embedded_digest: "held", embedded_at: Time.current)
      SearchIndex.index(hidden.reload)
    end

    SearchIndex.refresh!

    Tenant.switch(@demo) do
      assert_empty SearchIndex.nearest(near, tenant: @demo, limit: 50)
    end
  end

  test "kind narrows a vector query too" do
    Tenant.switch(@demo) do
      pdf = create_feed(mime: "application/pdf", title: "one")
      image = create_feed(mime: "image/jpeg", title: "two")

      [ pdf, image ].each do |item|
        item.update_columns(embedding: near, embedded_digest: "held", embedded_at: Time.current)
        SearchIndex.index(item.reload)
      end

      SearchIndex.refresh!

      assert_equal [ pdf.id ], SearchIndex.nearest(near, tenant: @demo, mime: "application/pdf", limit: 50)
    end
  end

  test "search still answers when no backend can embed the query" do
    Tenant.switch(@demo) do
      Resource.find_by!(key: "ollama").update!(details: { "base_url" => @server.base_url,
                                                          "models" => { "fast" => "gemma3:4b" } })

      match = create_feed(mime: "application/pdf", title: "March invoice")
      SearchIndex.refresh!

      assert_equal [ match.id ], Feed.search("March invoice").map(&:id)
      assert_empty @server.embedded, "with no embedding model declared, nothing should be asked"
    end
  end

  test "paging past the fusion window falls back to the lexical order it can page" do
    Tenant.switch(@demo) do
      create_feed(mime: "application/pdf", title: "March invoice")
      SearchIndex.refresh!

      page = Feed.found("invoice", limit: 10, from: SearchIndex::CANDIDATES)

      assert_empty page.nodes
      assert_empty @server.embedded, "a window past the candidates cannot be fused, so do not embed"
    end
  end

  test "a query is embedded once and then held" do
    Tenant.switch(@demo) do
      create_feed(mime: "application/pdf", title: "March invoice")
      SearchIndex.refresh!

      3.times { Feed.search("quarterly report") }

      assert_equal 1, @server.embedded.count("search_query: quarterly report")
    end
  end

  private

    def near
      @near ||= Array.new(WIDTH) { |index| index == 7 ? 1.0 : 0.0 }
    end

    def far
      @far ||= Array.new(WIDTH) { |index| Math.sin(index * 1.7) }
    end

    def leaning
      @leaning ||= near.zip(far).map { |one, other| one + (other * 0.037) }
    end
end
