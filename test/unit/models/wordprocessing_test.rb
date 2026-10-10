require "test_helper"

class WordprocessingTest < ActiveSupport::TestCase
  DOCX_BODY = <<~XML.freeze
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
      <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Condition report</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Roof</w:t></w:r></w:p>
      <w:p><w:r><w:t>The felt has lifted.</w:t></w:r><w:r><w:tab/><w:t>Tacks pulled through.</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Drainage</w:t></w:r></w:p>
      <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Gully</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>blocked</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    </w:body></w:document>
  XML

  ODT_BODY = <<~XML.freeze
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
      xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
      xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
      <office:body><office:text>
        <text:h text:outline-level="1">Roof</text:h>
        <text:p>The felt has lifted.</text:p>
        <text:list><text:list-item><text:p>Re-tack the overlap</text:p></text:list-item></text:list>
        <text:h text:outline-level="2">Drainage</text:h>
        <table:table><table:table-row><table:table-cell><text:p>Gully</text:p></table:table-cell><table:table-cell><text:p>blocked</text:p></table:table-cell></table:table-row></table:table>
      </office:text></office:body>
    </office:document-content>
  XML

  test "a Word document keeps its headings as sections and its tables as rows" do
    text = packed("word/document.xml" => DOCX_BODY) { |path| Wordprocessing.text(path, Wordprocessing::DOCX) }

    assert_equal "# Condition report\n\n# Roof\n\nThe felt has lifted.\tTacks pulled through.\n\n## Drainage\n\nGully | blocked", text
    assert_equal [ "Condition report", "Roof", "Drainage" ], Outline.of(text).map { |part| part["name"] }
  end

  test "an OpenDocument text keeps its headings, its lists, and its tables" do
    text = packed("content.xml" => ODT_BODY) { |path| Wordprocessing.text(path, Wordprocessing::ODT) }

    assert_equal "# Roof\n\nThe felt has lifted.\n\nRe-tack the overlap\n\n## Drainage\n\nGully | blocked", text
  end

  test "a file that is not a document reads as nothing, so the pdf's text is used" do
    Tempfile.create([ "broken", ".docx" ]) do |file|
      file.write("not a zip")
      file.flush

      assert_nil Wordprocessing.text(file.path, Wordprocessing::DOCX)
    end
  end

  test "HTML keeps its headings as sections and each block on a line of its own" do
    text = Markup.strip("<h1>Shed <em>diaries</em></h1><p>The felt roof &amp; tacks.</p><h2>Plan</h2><ul><li>Prime</li><li>Felt</li></ul>")

    assert_equal "# Shed diaries\n\nThe felt roof & tacks.\n\n## Plan\n\nPrime\nFelt", text
  end

  private

    def packed(entries)
      Tempfile.create([ "document", ".zip" ]) do |file|
        Zip::OutputStream.open(file.path) do |zip|
          entries.each do |name, body|
            zip.put_next_entry(name)
            zip.write(body)
          end
        end

        yield file.path
      end
    end
end
