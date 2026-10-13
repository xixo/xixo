require "test_helper"

class CatalogSummaryTest < ActionDispatch::IntegrationTest
  FEED = "query($id: ID) { feed(id: $id) { summary unsummarized } }".freeze

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "gist-#{SecureRandom.hex(4)}", name: "Gist")
    connect!(@tenant)
  end

  test "with no summary yet, a file offers the start of what it says rather than every step's output" do
    feed = Tenant.switch(@tenant) do
      held = Feed.create!(type: Feed::FILE, key: "march.pdf", title: "march.pdf")
      Analysis.open!(feed: held, cause: "upload").tap do |analysis|
        analysis.write_step!("info", { "result" => { "pages" => 1, "size" => "612 x 792 pts (letter)" } })
        analysis.write_step!("text", { "result" => "# Invoice\n\nfor **March**, totalling 42 pounds" })
        analysis.finished!
      end
      held
    end

    assert_equal "Invoice for March, totalling 42 pounds", summary_of(feed)
  end

  test "a note with no bytes offers what was written on it" do
    feed = Tenant.switch(@tenant) { Feed.create!(type: Feed::NOTE, key: "Shopping", title: "Shopping", note: "milk, bread") }

    assert_equal "milk, bread", summary_of(feed)
  end

  test "a file whose passes read no text offers nothing rather than its metadata" do
    feed = Tenant.switch(@tenant) do
      held = Feed.create!(type: Feed::FILE, key: "photo.heic", title: "photo.heic")
      Analysis.open!(feed: held, cause: "upload").tap do |analysis|
        analysis.write_step!("dimensions", { "result" => { "width" => 4032 } })
        analysis.finished!
      end
      held
    end

    assert_nil summary_of(feed)
  end

  test "the text OCR read off a screenshot is never offered as its summary" do
    feed = Tenant.switch(@tenant) do
      held = Feed.create!(type: Feed::FILE, key: "Screenshot.png", title: "Screenshot.png")
      Analysis.open!(feed: held, cause: "upload").tap do |analysis|
        analysis.write_step!("ocr", { "result" => "» Quickstart masks X fq All Search powere X masks" })
        analysis.finished!
      end
      held
    end

    assert_nil summary_of(feed)
  end

  test "an image no model could read says why it has no summary" do
    feed = Tenant.switch(@tenant) do
      held = Feed.create!(type: Feed::FILE, key: "dog.jpeg", title: "dog.jpeg")
      Analysis.open!(feed: held, cause: "upload").tap do |analysis|
        analysis.write_step!("dropped", { "result" => { "summary" => "No model backend reads images, so it was not described." } })
        analysis.finished!
      end
      held
    end

    assert_nil summary_of(feed)
    assert_equal "No model backend reads images, so it was not described.", feed_field(feed, "unsummarized")
  end

  test "a summary that failed says what went wrong, and a written one clears it" do
    feed = Tenant.switch(@tenant) do
      held = Feed.create!(type: Feed::FILE, key: "dog.jpeg", title: "dog.jpeg")
      Analysis.open!(feed: held, cause: "upload").tap do |analysis|
        analysis.write_step!("summary", { "finished_at" => Time.current.iso8601(3),
                                          "error" => { "class" => "Resource::Unusable", "message" => "ollama answered 400" } })
        analysis.finished!
      end
      held
    end

    assert_equal "The summary failed. ollama answered 400", feed_field(feed, "unsummarized")

    Tenant.switch(@tenant) do
      Analysis.open!(feed: feed, cause: "manual").tap do |analysis|
        analysis.write_step!("summary", { "result" => { "summary" => "A Pomeranian on a lawn." } })
        analysis.finished!
      end
    end

    assert_nil feed_field(feed, "unsummarized")
    assert_equal "A Pomeranian on a lawn.", summary_of(feed)
  end

  private

    def summary_of(feed)
      feed_field(feed, "summary")
    end

    def feed_field(feed, name)
      post "/graphql",
           params: { query: FEED, variables: { id: feed.id.to_s }.to_json },
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test" }.merge(bearer)

      response.parsed_body.dig("data", "feed", name)
    end

    def bearer
      token = issuer.mint(
        subdomain: @tenant.subdomain, scopes: Grant::SCOPES,
        audience: "http://#{@tenant.subdomain}.xixo.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end
end
