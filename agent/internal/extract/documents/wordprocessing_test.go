package documents

import (
	"archive/zip"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func zipped(t *testing.T, name, entry, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	part, err := w.Create(entry)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func golden(t *testing.T, group, name string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "golden", group, name+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var held map[string]any
	if err := json.Unmarshal(raw, &held); err != nil {
		t.Fatal(err)
	}
	return held
}

func goldenText(t *testing.T, group, name, step string) string {
	t.Helper()
	steps := golden(t, group, name)["steps"].(map[string]any)
	said, _ := steps[step].(map[string]any)["result"].(string)
	return said
}

func TestDocxHeadingsParagraphsAndTables(t *testing.T) {
	body := `<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Survey   notes</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Heading2"/><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:r><w:t>Roof</w:t></w:r></w:p>
<w:p><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:r><w:t>Gutters</w:t></w:r></w:p>
<w:p><w:r><w:t>Felt</w:t><w:tab/><w:t>lifted</w:t><w:br/><w:t>north corner</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">   </w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cost</w:t></w:r></w:p></w:tc></w:tr>
<w:tr><w:tc><w:p><w:r><w:t>Clout </w:t></w:r><w:r><w:t>nails</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>6.40</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:pPr><w:pStyle w:val="heading 9"/></w:pPr><w:r><w:t>Deep</w:t></w:r></w:p>
</w:body></w:document>`
	path := zipped(t, "notes.docx", "word/document.xml", body)

	want := "# Survey notes\n\n## Roof\n\n### Gutters\n\nFelt\tlifted\nnorth corner\n\nItem | Cost\nClout nails | 6.40\n\n###### Deep"
	if got := WordprocessingText(path, Docx); got != want {
		t.Fatalf("docx text\n got %q\nwant %q", got, want)
	}
}

func TestOdtHeadingsListsSectionsAndTables(t *testing.T) {
	body := `<?xml version="1.0"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
<office:body><office:text>
<text:h text:outline-level="2">Drainage   plan</text:h>
<text:p>  Rear gully <text:span>blocked</text:span>  </text:p>
<text:list><text:list-item><text:p>Clear leaves</text:p></text:list-item></text:list>
<text:section><text:p>Inside a section</text:p></text:section>
<table:table><table:table-row><table:table-cell><text:p>Item</text:p></table:table-cell><table:table-cell><text:p>Cost</text:p></table:table-cell></table:table-row>
<table:table-row><table:table-cell><text:p>Rodding</text:p></table:table-cell><table:table-cell><text:p>80</text:p></table:table-cell></table:table-row></table:table>
<text:h text:outline-level="0">Level zero</text:h>
<text:h text:outline-level="2">   </text:h>
</office:text></office:body></office:document-content>`
	path := zipped(t, "plan.odt", "content.xml", body)

	want := "## Drainage plan\n\nRear gully blocked\n\nClear leaves\n\nInside a section\n\nItem | Cost\nRodding | 80\n\n# Level zero"
	if got := WordprocessingText(path, Odt); got != want {
		t.Fatalf("odt text\n got %q\nwant %q", got, want)
	}
}

func TestWordprocessingSurvivesBrokenFiles(t *testing.T) {
	notZip := filepath.Join(t.TempDir(), "broken.docx")
	if err := os.WriteFile(notZip, []byte("not a zip"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := WordprocessingText(notZip, Docx); got != "" {
		t.Fatalf("a file that is not a zip read as %q", got)
	}
	if got := WordprocessingText(zipped(t, "empty.docx", "word/other.xml", "<x/>"), Docx); got != "" {
		t.Fatalf("a docx with no document read as %q", got)
	}
	if got := WordprocessingText(zipped(t, "bad.odt", "content.xml", "<office:text"), Odt); got != "" {
		t.Fatalf("malformed xml read as %q", got)
	}
}

func TestCorpusDocumentsMatchWhatRubyRead(t *testing.T) {
	for name, mime := range map[string]string{"report.docx": Docx, "report.odt": Odt} {
		got := WordprocessingText(filepath.Join("testdata", name), mime)
		if want := goldenText(t, "doc", name, "text"); got != want {
			t.Errorf("%s\n got %q\nwant %q", name, got, want)
		}
		if !strings.Contains(got, "CONDITION-") {
			t.Errorf("%s lost its needle", name)
		}
	}
}
