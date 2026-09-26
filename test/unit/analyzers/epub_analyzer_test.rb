require "test_helper"

class EpubAnalyzerTest < ActiveSupport::TestCase
  CORPUS = Rails.root.join("test/fixtures/corpus/other/book.epub")

  setup do
    @tenant = Tenant.create!(subdomain: "epub-#{SecureRandom.hex(4)}", name: "Books")
    Tenant.switch(@tenant) { @storage = Resource::Database.create!(key: "shelf", name: "Shelf") }
  end

  def read(name, body)
    Tenant.switch(@tenant) do
      @storage.upload(name, body)
      feed = Feed.create!(type: Feed::FILE, key: name, title: name)
      Reference.record!(feed: feed, resource: @storage, locator_key: name, locator: { "key" => name })
      analysis = Analysis.open!(feed: feed, cause: "manual")

      analyzer = Analyzer.for(feed.reload, analysis: analysis)
      yield analyzer if block_given?
      analyzer.analyze

      analysis.reload.steps.transform_values { |step| step["result"] }
    end
  end

  def book(files, opf:)
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("mimetype")
      zip.write("application/epub+zip")
      zip.put_next_entry("META-INF/container.xml")
      zip.write(%(<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>) +
                %(<rootfile full-path="text/book.opf"/></rootfiles></container>))
      zip.put_next_entry("text/book.opf")
      zip.write(opf)
      files.each do |name, body|
        zip.put_next_entry(name)
        zip.write(body)
      end
    end.string
  end

  def chapter(words)
    %(<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Head</title><style>p{}</style></head>) +
      %(<body><h1>#{words}</h1><p>#{words} continues.</p><script>no()</script></body></html>)
  end

  test "an epub is read by its own analyzer, not as a zip" do
    steps = read("book.epub", CORPUS.binread) { |analyzer| assert_instance_of Analyzer::Epub, analyzer }

    assert_equal "Shed Diaries", steps["book"]["title"]
    assert_equal [ "Bea Okonkwo" ], steps["book"]["creators"]
    assert_equal [ "OEBPS/chapter1.xhtml" ], steps["book"]["chapters"]

    assert_includes steps["text"], "Title: Shed Diaries"
    assert_includes steps["text"], "By: Bea Okonkwo"
    assert_includes steps["text"], "EPUBCHAPTER-5540"
    assert_includes steps["text"], "The felt roof, again\nLifted at the north corner after the gales."
    assert_not_includes steps["text"], "<"
  end

  test "chapters are read in spine order, and markup, scripts and the head are left out" do
    opf = <<~OPF
      <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <metadata><dc:title>Two Rooms</dc:title><dc:subject>Sheds</dc:subject><dc:subject>Roofs</dc:subject>
          <dc:description>&lt;p&gt;About &lt;b&gt;sheds&lt;/b&gt;.&lt;/p&gt;</dc:description></metadata>
        <manifest>
          <item id="b" href="../parts/second%20part.xhtml#top" media-type="application/xhtml+xml"/>
          <item id="a" href="first.xhtml" media-type="application/xhtml+xml"/>
          <item id="css" href="style.css" media-type="text/css"/>
        </manifest>
        <spine><itemref idref="a"/><itemref idref="css"/><itemref idref="b"/><itemref idref="gone"/></spine>
      </package>
    OPF

    steps = read("rooms.epub", book({ "text/first.xhtml" => chapter("Alpha"),
                                      "parts/second part.xhtml" => chapter("Beta") }, opf: opf))

    assert_equal [ "text/first.xhtml", "parts/second part.xhtml" ], steps["book"]["chapters"]
    assert_operator steps["text"].index("Alpha"), :<, steps["text"].index("Beta")
    assert_includes steps["text"], "Subjects: Sheds, Roofs"
    assert_includes steps["text"], "Description: About sheds ."
    assert_not_includes steps["text"], "Head"
    assert_not_includes steps["text"], "no()"
  end

  test "an encrypted chapter is skipped rather than read as noise, and a book encrypted throughout says so" do
    opf = <<~OPF
      <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <metadata><dc:title>Locked</dc:title><dc:creator>Cy</dc:creator></metadata>
        <manifest><item id="a" href="first.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="a"/></spine>
      </package>
    OPF
    encryption = <<~XML
      <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
        <enc:EncryptedData><enc:CipherData><enc:CipherReference URI="text/first.xhtml"/></enc:CipherData></enc:EncryptedData>
      </encryption>
    XML

    steps = read("locked.epub", book({ "text/first.xhtml" => "\x8F\x02ciphertext",
                                       "META-INF/encryption.xml" => encryption }, opf: opf))

    assert_equal [ "text/first.xhtml" ], steps["book"]["encrypted"]
    assert_includes steps["text"], "Title: Locked"
    assert_includes steps["text"], "Its chapters are encrypted"
    assert_not_includes steps["text"], "ciphertext"
  end

  test "a file that is not a zip fails the read with a reason" do
    error = assert_raises(Analyzer::Failed) { read("broken.epub", "not a zip at all") }

    assert_match(/unreadable epub/, error.message)
  end
end
