package plain

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/xixo/xixo/agent/internal/extract"
)

const corpus = "../../../../test/fixtures/corpus"

func run(t *testing.T, path, mime string) *extract.Output {
	t.Helper()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	chosen := extract.For(mime, filepath.Base(path))
	if chosen == nil {
		t.Fatalf("no extractor for %s", mime)
	}

	out, err := chosen.Extract(context.Background(), extract.Input{
		Path: path, Name: filepath.Base(path), MIME: mime, Size: info.Size(), Work: t.TempDir(),
		Run: extract.Limited{},
	})
	if err != nil {
		t.Fatal(err)
	}

	return out
}

func fixture(t *testing.T, name string) string {
	t.Helper()

	path := filepath.Join(corpus, name)
	if _, err := os.Stat(path); err != nil {
		t.Skip("the corpus is not checked out; copy test/fixtures/corpus from the main checkout")
	}

	return path
}

func text(out *extract.Output) string {
	held, _ := out.Steps["text"].Result.(string)

	return held
}

func TestCorpusNeedlesReachTheText(t *testing.T) {
	cases := map[string]string{
		"text/null-bytes.txt":                       "NULBYTE-LOGFRAGMENT-9975",
		"text/notes.txt":                            "PLAINTEXT-MARMALADE-7742",
		"text/emoji.txt":                            "UNICODE-PACKINGLIST-4457",
		"text/latin1.txt":                           "LATIN1-INVALIDUTF8-6613",
		"text/readme.md":                            "MARKDOWN-TIMETABLE-3391",
		"text/utf16le.txt":                          "UTF16LE-2286",
		"text/crlf.txt":                             "CRLF-ENDINGS-8820",
		"text/utf8-bom.txt":                         "BOM-PREFIXED-1204",
		"data/feed.xml":                             "RSSFEED-3520",
		"data/quoted.csv":                           "QUOTEDCSV-4416",
		"calendar/meeting.ics":                      "ICSFOLDED",
		"contact/contacts.vcf":                      "VCARD4-OKONKWO-3388",
		"contact/photo.vcf":                         "VCARDPHOTO-THORNE-4471",
		"other/page.html":                           "HTMLPAGE-7729",
		"other/a file with spaces & symbols #1.txt": "AWKWARDNAME-3852",
		"other/ファイル名.txt":                           "UNICODENAME-6031",
		"other/UPPERCASE.TXT":                       "UPPEREXT-7266",
		"other/no-extension":                        "NOEXTENSION-2914",
		"pkpass/not-a-zip.pkpass":                   "",
	}

	for name, needle := range cases {
		t.Run(name, func(t *testing.T) {
			path := fixture(t, name)
			out := run(t, path, mimeFor(name))

			if needle != "" && !strings.Contains(text(out), needle) {
				t.Fatalf("%s is missing from the text of %s: %q", needle, name, extract.Truncate(text(out), 300))
			}
		})
	}
}

func mimeFor(name string) string {
	switch extract.Extension(name) {
	case "txt":
		return "text/plain"
	case "md":
		return "text/markdown"
	case "xml":
		return "application/xml"
	case "csv":
		return "text/csv"
	case "tsv":
		return "text/tab-separated-values"
	case "json":
		return "application/json"
	case "ics":
		return "text/calendar"
	case "vcf":
		return "text/vcard"
	case "pkpass":
		return "application/vnd.apple.pkpass"
	case "html":
		return "text/html"
	case "rtf":
		return "text/rtf"
	default:
		return "application/octet-stream"
	}
}

func TestEveryContactBecomesASection(t *testing.T) {
	out := run(t, fixture(t, "contact/contacts.vcf"), "text/vcard")

	for _, needle := range []string{"VCARD3-PEMBERTON-7104", "VCARD4-OKONKWO-3388", "VCARDAPPLE-VANE-9265"} {
		if !strings.Contains(text(out), needle) {
			t.Fatalf("%s is missing", needle)
		}
	}

	sections := out.Steps["outline"].Result.([]extract.Section)
	contacts := out.Steps["contacts"].Result.([]Card)

	if len(sections) != len(contacts) || len(contacts) < 3 {
		t.Fatalf("%d sections for %d contacts", len(sections), len(contacts))
	}
}

func TestACalendarCapsItsEvents(t *testing.T) {
	out := run(t, fixture(t, "calendar/many-events.ics"), "text/calendar")

	if len(out.Steps["events"].Result.([]Event)) > MostEvents {
		t.Fatal("too many events")
	}

	if out.Dropped["events"] == "" {
		t.Fatal("the cut went unsaid")
	}
}

func TestReadAsWritesADate(t *testing.T) {
	cases := map[string]string{
		"20261012":         "Monday, October 12, 2026",
		"20261012T093000Z": "Monday, October 12, 2026, 09:30 UTC",
		"20261012T093000":  "Monday, October 12, 2026, 09:30",
		"20261332":         "20261332",
		"soon":             "soon",
	}

	for held, want := range cases {
		if got := ReadAs(held); got != want {
			t.Errorf("ReadAs(%q) = %q, want %q", held, got, want)
		}
	}
}

func TestDataFramesTablesAndShapes(t *testing.T) {
	out := run(t, fixture(t, "data/rows.csv"), "text/csv")

	tables := out.Steps["tables"].Result.([]*extract.Table)
	if len(tables) != 1 || len(tables[0].Columns) < 2 || len(tables[0].Rows) == 0 {
		t.Fatalf("got %+v", tables)
	}

	shape := out.Steps["shape"].Result.(Shape)
	if shape.Format != "csv" || shape.Rows == nil || *shape.Rows == 0 {
		t.Fatalf("got %+v", shape)
	}

	broken := run(t, fixture(t, "data/broken.json"), "application/json").Steps["shape"].Result.(Shape)
	if broken.Format != "invalid" {
		t.Fatalf("got %+v", broken)
	}

	config := run(t, fixture(t, "data/config.json"), "application/json").Steps["shape"].Result.(Shape)
	if config.Format != "json" || len(config.Keys) == 0 {
		t.Fatalf("got %+v", config)
	}

	listed := run(t, fixture(t, "data/array.json"), "application/json").Steps["shape"].Result.(Shape)
	if listed.Format != "json" || len(listed.Keys) != 0 {
		t.Fatalf("got %+v", listed)
	}

	ragged := run(t, fixture(t, "data/ragged.csv"), "text/csv")
	if _, ok := ragged.Steps["tables"]; !ok {
		t.Fatal("a ragged file still records its tables, even an empty list")
	}
}

func TestPassesReadTheirFields(t *testing.T) {
	out := run(t, fixture(t, "pkpass/boarding.pkpass"), "application/vnd.apple.pkpass")

	pass := out.Steps["pass"].Result.(*Pass)
	if pass.Style != "boardingPass" || len(pass.Fields) == 0 || text(out) == "" {
		t.Fatalf("got %+v", pass)
	}

	for _, name := range []string{"pkpass/bad-json.pkpass", "pkpass/no-pass-json.pkpass", "pkpass/not-a-zip.pkpass"} {
		failed := run(t, fixture(t, name), "application/vnd.apple.pkpass")
		if failed.Steps["pass"].Error == "" {
			t.Fatalf("%s should fail its pass step", name)
		}
	}
}

func TestFallbackListsArchivesAndSniffs(t *testing.T) {
	for _, name := range []string{"other/archive.zip", "other/archive.tar.gz"} {
		out := run(t, fixture(t, name), "application/octet-stream")

		listed, ok := out.Steps["listing"].Result.([]string)
		if !ok || len(listed) == 0 {
			t.Fatalf("%s listed %+v", name, out.Steps["listing"])
		}
	}

	pem := run(t, fixture(t, "other/certificate.pem"), "application/octet-stream")
	if pem.Steps["format"].Result.(Format).Observed != "text" {
		t.Fatalf("got %+v", pem.Steps["format"])
	}

	mp3 := run(t, fixture(t, "other/tone.mp3"), "application/octet-stream")
	if mp3.Steps["format"].Result.(Format).Printable {
		t.Fatal("audio is not printable")
	}

	if _, ok := mp3.Steps["text"]; ok {
		t.Fatal("audio has no text")
	}
}

func TestStepsEncodeAsJSON(t *testing.T) {
	out := run(t, fixture(t, "contact/contacts.vcf"), "text/vcard")

	if _, err := json.Marshal(out); err != nil {
		t.Fatal(err)
	}
}
