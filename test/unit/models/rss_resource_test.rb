require "test_helper"
require_relative "../../support/fake_feed_server"

class RssResourceTest < ActiveSupport::TestCase
  ITEMS = [
    { id: "urn:one", title: "The first post", link: "https://elsewhere.example/one",
      description: "<p>Something <b>about</b> pelicans.</p>" },
    { id: "urn:two", title: "The second post", link: "https://elsewhere.example/two",
      description: "<p>Rather more about pelicans.</p>" }
  ].freeze

  setup do
    SearchIndex.reset!

    ENV["XIXO_ALLOW_PRIVATE_FETCH"] = "1"

    @server = FakeFeedServer.current
    @server.reset!
    @feed = @server.serve_body("/feed.xml", @server.rss(ITEMS))

    @tenant = Tenant.create!(subdomain: "rss-#{SecureRandom.hex(4)}", name: "Feeds")

    Tenant.switch(@tenant) do
      @resource = Resource::Rss.create!(
        key: "feed-#{SecureRandom.hex(4)}", name: "A feed", details: { "url" => @feed }
      )
    end
  end

  teardown do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")
  end

  test "syncing a feed catalogues every entry, keyed on its guid" do
    sync

    Tenant.switch(@tenant) do
      assert_equal 2, Feed.files.count
      assert_equal [ MimeType::ENTRY, MimeType::ENTRY ], Reference.pluck(:mime)
      assert_equal [ "The first post", "The second post" ], Feed.pluck(:title).sort
      assert_equal %w[urn:one urn:two], Reference.pluck(:locator_key).sort
    end
  end

  test "the reference points at something we do not hold" do
    sync

    Tenant.switch(@tenant) do
      locator = titled("The first post").references.first.locator

      assert_equal "https://elsewhere.example/one", locator["link"]
      assert_equal "urn:one", locator["id"]
    end
  end

  test "atom parses the same way rss does" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "url" => @server.serve_body("/atom.xml", @server.atom(ITEMS)) })
      sync

      assert_equal 2, Feed.files.count
      assert_equal "https://elsewhere.example/two", titled("The second post").references.first.locator["link"]
    end
  end

  test "syncing twice converges rather than accumulating" do
    2.times { sync }

    Tenant.switch(@tenant) { assert_equal 2, Feed.files.count }
  end

  test "the analyzer indexes the entry body as text, tags stripped" do
    sync

    Tenant.switch(@tenant) do
      item = titled("The first post")
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, item.id) }

      analysis = item.reload.analysis.steps

      assert_equal "https://elsewhere.example/one", analysis.dig("entry", "result", "link")
      assert_includes analysis.dig("text", "result"), "Something about pelicans."
      assert_not_includes analysis.dig("text", "result"), "<b>"
    end
  end

  test "an entry edited in place is a new version, though its date never moved" do
    sync
    before = Tenant.switch(@tenant) { Reference.find_by!(locator_key: "urn:two").version }

    edited = ITEMS.map { |item| item[:id] == "urn:two" ? item.merge(description: "<p>A correction about pelicans.</p>") : item }
    @server.serve_body("/feed.xml", @server.rss(edited))
    sync

    Tenant.switch(@tenant) do
      assert_not_equal before, Reference.find_by!(locator_key: "urn:two").version
      assert Reference.find_by!(locator_key: "urn:two").changed_at.present?
      assert_nil Reference.find_by!(locator_key: "urn:one").changed_at
    end
  end

  test "an entry that scrolls out of the window is gone, not silently empty" do
    sync
    @server.serve_body("/feed.xml", @server.rss([ ITEMS.last ]))

    Tenant.switch(@tenant) do
      error = assert_raises(Resource::Rss::Gone) { titled("The first post").references.first.download }

      assert_match(/scrolled out/, error.message)
    end
  end

  test "a private address is refused unless fetching them is allowed" do
    ENV.delete("XIXO_ALLOW_PRIVATE_FETCH")

    error = assert_raises(Resource::Rss::Blocked) { @resource.check! }

    assert_match(/not a public address/, error.message)
  end

  test "a redirect is followed" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "url" => @server.serve_redirect("/hop", @feed) })
      sync

      assert_equal 2, Feed.files.count
    end
  end

  test "the guard runs again on whatever a redirect points at" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "url" => @server.serve_redirect("/hop", "file:///etc/passwd") })

      error = assert_raises(Resource::Rss::Blocked) { @resource.check! }

      assert_match(/not an http or https URL/, error.message)
    end
  end

  test "a redirect loop stops rather than spinning" do
    Tenant.switch(@tenant) do
      @server.serve_redirect("/loop", @server.url_for("/loop"))
      @resource.update!(details: { "url" => @server.url_for("/loop") })

      error = assert_raises(Resource::Failed) { @resource.check! }

      assert_match(/too many redirects/, error.message)
    end
  end

  test "a non-http scheme is refused before anything is opened" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "url" => "file:///etc/passwd" })

      error = assert_raises(Resource::Rss::Blocked) { @resource.check! }

      assert_match(/not an http or https URL/, error.message)
    end
  end

  test "a feed that is not xml fails loudly" do
    Tenant.switch(@tenant) do
      @resource.update!(details: { "url" => @server.serve_body("/nope", "not xml at all") })

      assert_raises(Resource::Failed) { @resource.check! }
    end
  end

  test "it is not storage and cannot be an export destination" do
    assert_not @resource.storage?
    assert_raises(ArgumentError) { @resource.storage! }
  end

  private

    def sync
      Tenant.switch(@tenant) { SyncResourceJob.perform_now(@tenant.id, @resource.id) }
    end

    def titled(title)
      Feed.find_by!(title: title)
    end
end
