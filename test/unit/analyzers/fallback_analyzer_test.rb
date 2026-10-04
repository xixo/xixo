require "test_helper"

class FallbackAnalyzerTest < ActiveSupport::TestCase
  CORPUS = Rails.root.join("test/fixtures/corpus/other/archive.tar.gz")

  setup do
    @tenant = Tenant.create!(subdomain: "fallback-#{SecureRandom.hex(4)}", name: "Odds")
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "drawer", name: "Drawer") }
  end

  def read(name, body)
    Tenant.switch(@tenant) do
      @storage.upload(name, body)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      analysis = Analysis.open!(feed: feed, cause: "manual")

      analyzer = Analyzer.for(feed.reload, analysis: analysis)
      analyzer.analyze

      [ analysis.reload.steps.transform_values { |step| step["result"] }, analyzer ]
    end
  end

  def tar(files)
    io = StringIO.new("".b)
    Gem::Package::TarWriter.new(io) do |writer|
      files.each { |name, body| writer.add_file_simple(name, 0o644, body.bytesize) { |entry| entry.write(body) } }
    end
    io.string
  end

  def gzipped(bytes)
    io = StringIO.new("".b)
    Zlib::GzipWriter.wrap(io) { |gzip| gzip.write(bytes) }
    io.string
  end

  test "a gzipped tar is listed entry by entry, and the summary is asked about the names" do
    steps, analyzer = read("archive.tar.gz", CORPUS.binread)

    assert_equal "gzip", steps.dig("format", "observed")
    assert_equal %w[notes.txt readme.md], steps["listing"]
    assert_includes analyzer.summary_body, "Archive entries:\nnotes.txt\nreadme.md"
  end

  test "a plain tar is recognized by its header and listed" do
    steps, = read("bundle.tar", tar("a/one.txt" => "one", "b/two.csv" => "x,y"))

    assert_equal "tar", steps.dig("format", "observed")
    assert_equal %w[a/one.txt b/two.csv], steps["listing"]
  end

  test "a gzip that holds no tar is not taken for an archive" do
    steps, = read("notes.txt.gz", gzipped("just some notes\n" * 40))

    assert_equal "gzip", steps.dig("format", "observed")
    assert_not steps.key?("listing")
  end
end
