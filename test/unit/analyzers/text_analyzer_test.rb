require "test_helper"

class TextAnalyzerTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "text-#{SecureRandom.hex(4)}", name: "Words")
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "desk", name: "Desk") }
  end

  def text_of(name, body, stored: nil)
    Tenant.switch(@tenant) do
      @storage.upload(name, body)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      analysis = Analysis.open!(feed: feed, cause: "manual")
      analysis.update!(steps: { "text" => stored }) if stored

      Analyzer.for(feed.reload, analysis: analysis).analyze

      analysis.reload.steps.dig("text", "result")
    end
  end

  test "Latin-1 text is read as the characters it was written in" do
    assert_equal "Café, résumé, naïve", text_of("latin1.txt", "Caf\xE9, r\xE9sum\xE9, na\xEFve".b)
  end

  test "Windows-1252 punctuation comes through as itself" do
    assert_equal "“quoted” – dash", text_of("quotes.txt", "\x93quoted\x94 \x96 dash".b)
  end

  test "UTF-16 with a byte order mark is decoded" do
    assert_equal "Café ☕", text_of("utf16.txt", "\xFF\xFE".b + "Café ☕".encode(Encoding::UTF_16LE).b)
  end

  test "a UTF-8 byte order mark is dropped and the rest is untouched" do
    assert_equal "naïve 🙂", text_of("bom.txt", "\xEF\xBB\xBFnaïve 🙂".b)
  end

  test "text read before the decoder existed is read again" do
    scrubbed = { "result" => "Caf\uFFFD", "started_at" => 1.day.ago.iso8601(3), "finished_at" => 1.day.ago.iso8601(3) }

    assert_equal "Café", text_of("old.txt", "Caf\xE9".b, stored: scrubbed)
  end

  test "text past the most that is read says how much was left out, and still says so once it is cached" do
    Tenant.switch(@tenant) do
      @storage.upload("long.txt", "word " * 50_000)
      feed = Feed.create!(type: Feed::FILE, key: "long.txt", title: "long.txt")
      Reference.record!(feed: feed, resource: @storage, locator_key: "long.txt", locator: { "key" => "long.txt" })

      2.times do
        analysis = Analysis.open!(feed: feed, cause: "manual")
        Analyzer.for(feed.reload, analysis: analysis).run
        rows = Details.of(analysis.reload).map { |row| [ row.group, row.label, row.value ] }

        assert_includes rows, [ "Left out", "Text", "only the first 200,000 of 249,999 characters were read" ]
      end
    end
  end
end
