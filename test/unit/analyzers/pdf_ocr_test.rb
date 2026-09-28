require "test_helper"

class PdfOcrTest < ActiveSupport::TestCase
  CORPUS = Rails.root.join("test/fixtures/corpus/pdf")

  setup do
    skip "no corpus on disk — see test/fixtures/corpus/README.md" unless CORPUS.exist?

    @tenant = Tenant.create!(subdomain: "ocr-#{SecureRandom.hex(4)}", name: "Scans")
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "scans", name: "Scans") }
  end

  def read(name)
    Tenant.switch(@tenant) do
      @storage.upload(name, CORPUS.join(name).binread)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      analysis = Analysis.open!(feed: feed, cause: "manual")

      Analyzer.for(feed.reload, analysis: analysis).analyze

      analysis.reload
    end
  end

  test "a scanned pdf with no text layer is read by ocr" do
    analysis = read("scanned.pdf")

    assert_includes analysis.steps.dig("text", "result"), "OCRRECEIPT-9042"
    assert_match(/no text layer, so ocr read 1 page\b/, analysis.logs)
  end

  test "a pdf with a text layer is read from it, without ocr" do
    analysis = read("invoice.pdf")

    assert_includes analysis.steps.dig("text", "result"), "PDFINVOICE-4820"
    assert_no_match(/ocr read/, analysis.logs.to_s)
  end
end
