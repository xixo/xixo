require "test_helper"
require_relative "../../support/fake_feed_server"

class PageAnalyzerTest < ActiveSupport::TestCase
  PAGE = <<~HTML.freeze
    <!doctype html>
    <html><head><title>A page about pelicans</title></head>
    <body style="margin:0"><h1>Pelicans</h1><p>Rather a lot about pelicans.</p></body></html>
  HTML

  setup do
    skip "no browser to render with" unless Snapshot.available?

    SearchIndex.reset!

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    @server = FakeFeedServer.current
    @server.reset!
    @url = @server.serve_body("/page.html", PAGE, content_type: "text/html")

    @tenant = Tenant.create!(subdomain: "pag-#{SecureRandom.hex(4)}", name: "Pages")

    Tenant.switch(@tenant) do
      Resource::Database.create!(key: "blobs", name: "Storage").make_default_storage!
      @resource = Resource::Web.create!(key: "web", name: "The web")
      @reference = @resource.snapshot!(@url)
    end
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "dispatch picks the page analyzer over the one that reads images" do
    Tenant.switch(@tenant) { assert_instance_of Analyzer::Page, Analyzer.for(@reference.feed) }
  end

  test "analysis records where the page was and what it rendered" do
    Tenant.switch(@tenant) do
      steps = analyzed.steps

      assert_equal @url, steps.dig("page", "result", "url")
      assert_equal "A page about pelicans", steps.dig("page", "result", "title")
      assert_operator steps.dig("page", "result", "height").to_i, :>, 0
      assert_match(/Rather a lot about pelicans/, steps.dig("text", "result"))
    end
  end

  test "the text a page rendered is what the catalog searches" do
    Tenant.switch(@tenant) do
      analyzed

      assert_match(/Rather a lot about pelicans/, @reference.feed.reload.readable_text)
    end
  end

  test "a page thumbnails from its capture rather than from its address" do
    Tenant.switch(@tenant) do
      assert Thumbnail.available_for?(MimeType::PAGE)

      tile = Thumbnail.for(@reference)

      assert_equal "\xFF\xD8".b, tile.byteslice(0, 2)
    end
  end

  private

    def analyzed
      feed = @reference.feed
      analysis = Analysis.open!(feed: feed, cause: "manual")

      Analyzer.for(feed, analysis: analysis).run
      analysis.finished!

      analysis.reload
    end
end
