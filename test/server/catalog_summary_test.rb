require "test_helper"

class CatalogSummaryTest < ActionDispatch::IntegrationTest
  FEED = "query($id: ID) { feed(id: $id) { summary } }".freeze

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

  private

    def summary_of(feed)
      post "/graphql",
           params: { query: FEED, variables: { id: feed.id.to_s }.to_json },
           headers: { "HOST" => "#{@tenant.subdomain}.xixo.test" }.merge(bearer)

      response.parsed_body.dig("data", "feed", "summary")
    end

    def bearer
      token = issuer.mint(
        subdomain: @tenant.subdomain, scopes: Grant::SCOPES,
        audience: "http://#{@tenant.subdomain}.xixo.test/mcp"
      )

      { "Authorization" => "Bearer #{token}" }
    end
end
