package rich

import (
	"archive/zip"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/agent/internal/extract"
)

func extracted(t *testing.T, e extract.Extractor, name, mime string) *extract.Output {
	t.Helper()

	path, err := filepath.Abs(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}

	return extractPath(t, e, path, name, mime, nil)
}

func extractPath(t *testing.T, e extract.Extractor, path, name, mime string, skip map[string]bool) *extract.Output {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	out, err := e.Extract(ctx, extract.Input{
		Path: path, Name: name, MIME: mime, Skip: skip, Work: t.TempDir(), Run: extract.Limited{},
	})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}

	return out
}

func result[T any](t *testing.T, out *extract.Output, step string) T {
	t.Helper()

	held, ok := out.Steps[step]
	if !ok {
		t.Fatalf("no %s step in %v", step, keys(out.Steps))
	}

	if held.Error != "" {
		t.Fatalf("%s failed: %s", step, held.Error)
	}

	encoded, err := json.Marshal(held.Result)
	if err != nil {
		t.Fatal(err)
	}

	var decoded T
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}

	return decoded
}

func keys(steps map[string]extract.Step) []string {
	names := []string{}
	for name := range steps {
		names = append(names, name)
	}

	return names
}

func needs(t *testing.T, programs ...string) {
	t.Helper()

	for _, program := range programs {
		if _, err := exec.LookPath(program); err != nil {
			t.Skipf("%s is not installed", program)
		}
	}
}

func TestRegisteredInTheExtractionOrder(t *testing.T) {
	for mime, want := range map[string]string{
		"audio/mpeg":               "media",
		"video/mp4":                "media",
		"message/rfc822":           "email",
		"application/epub+zip":     "epub",
		"application/vnd.ms-excel": "xlsx",
		"application/vnd.oasis.opendocument.spreadsheet": "xlsx",
	} {
		if got := extract.For(mime, "x"); got == nil || got.Name() != want {
			t.Errorf("%s went to %v, want %s", mime, got, want)
		}
	}
}

func TestEmailCarriesItsNeedleAndHeaders(t *testing.T) {
	for name, needle := range map[string]string{
		"plain.eml":            "EMAILPLAIN-4471",
		"html-only.eml":        "EMAILHTMLONLY-3390",
		"inline-image.eml":     "EMAILINLINE-5528",
		"nested-message.eml":   "EMAILNESTED-7704",
		"no-body.eml":          "EMAILNOBODY-2205",
		"not-a-message.eml":    "EMAILBROKEN-1193",
		"with-attachments.eml": "EMAILTEXT-8820",
	} {
		t.Run(name, func(t *testing.T) {
			out := extracted(t, Email{}, name, "message/rfc822")

			if text := result[string](t, out, "text"); !strings.Contains(text, needle) {
				t.Fatalf("the text lacks %s:\n%s", needle, text)
			}
		})
	}
}

func TestEmailDecodesEncodedHeaders(t *testing.T) {
	out := extracted(t, Email{}, "encoded-headers.eml", "message/rfc822")
	headers := result[map[string]string](t, out, "headers")

	if !strings.HasPrefix(headers["subject"], "Résumé for the 屋根 role") {
		t.Fatalf("subject %q", headers["subject"])
	}

	if !strings.Contains(result[string](t, out, "text"), "Subject: Résumé") {
		t.Fatal("the text does not start with the decoded headers")
	}
}

func TestEmailSplitsQuotedHistoryIntoItsOwnSection(t *testing.T) {
	out := extracted(t, Email{}, "flight-lisbon.eml", "message/rfc822")
	text := result[string](t, out, "text")
	outline := result[[]extract.Section](t, out, "outline")

	if !strings.HasPrefix(outline[0].Name, "Message from ") {
		t.Fatalf("outline %v", outline)
	}

	if len(outline) == 2 {
		if got := string([]rune(text)[outline[1].From:]); !strings.HasPrefix(got, "## "+Earlier) {
			t.Fatalf("the earlier section starts at %q", extract.Truncate(got, 40))
		}
	}

	split := Quoted("Sounds good.\n\nOn Tue, 3 Mar 2026, Bea wrote:\n> the key is under the mat\n> thanks\n")
	if split.Fresh != "Sounds good." || split.Earlier != "On Tue, 3 Mar 2026, Bea wrote:\nthe key is under the mat\nthanks" {
		t.Fatalf("split %+v", split)
	}
}

func TestEmailReturnsAttachmentsAsChildren(t *testing.T) {
	out := extracted(t, Email{}, "with-attachments.eml", "message/rfc822")
	attached := result[[]Attachment](t, out, "attachments")

	if len(attached) == 0 || len(out.Files) != len(attached) {
		t.Fatalf("attachments %v files %v", attached, out.Files)
	}

	for _, file := range out.Files {
		if file.Role != "child" || file.Name == "" || file.MIME == "" {
			t.Fatalf("file %+v", file)
		}

		held, err := os.Stat(file.Path)
		if err != nil || held.Size() == 0 {
			t.Fatalf("%s was not written: %v", file.Name, err)
		}
	}

	nested := extracted(t, Email{}, "nested-message.eml", "message/rfc822")
	if len(nested.Files) != 1 || nested.Files[0].Name != "forwarded.eml" || nested.Files[0].MIME != "message/rfc822" {
		t.Fatalf("the forwarded message is not a child: %+v", nested.Files)
	}
}

func TestEmailRefusesDeepNesting(t *testing.T) {
	var message strings.Builder
	message.WriteString("From: a@example.invalid\r\nSubject: deep\r\n")

	for depth := range 40 {
		message.WriteString("Content-Type: multipart/mixed; boundary=\"b" + strings.Repeat("x", depth) + "\"\r\n\r\n--b" + strings.Repeat("x", depth) + "\r\n")
	}

	message.WriteString("Content-Type: text/plain\r\n\r\nDEEPNEEDLE\r\n")

	path := filepath.Join(t.TempDir(), "deep.eml")
	if err := os.WriteFile(path, []byte(message.String()), 0o600); err != nil {
		t.Fatal(err)
	}

	out := extractPath(t, Email{}, path, "deep.eml", "message/rfc822", nil)

	if !strings.Contains(out.Dropped["parts"], "nested deeper") {
		t.Fatalf("dropped %v", out.Dropped)
	}
}

func TestEpubReadsBookAndChapters(t *testing.T) {
	out := extracted(t, Epub{}, "book.epub", "application/epub+zip")
	book := result[Book](t, out, "book")

	if book.Title == "" || len(book.Chapters) != 1 {
		t.Fatalf("book %+v", book)
	}

	if text := result[string](t, out, "text"); !strings.Contains(text, "EPUBCHAPTER-5540") || !strings.Contains(text, "Title: ") {
		t.Fatalf("text %q", text)
	}
}

func TestEpubBoundsWhatItUnzips(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bomb.epub")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}

	writer := zip.NewWriter(file)
	add := func(name, body string) {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}

		entry.Write([]byte(body))
	}

	add("META-INF/container.xml", `<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>`)
	add("content.opf", `<package><metadata><title>Bomb</title></metadata><manifest><item id="a" href="big.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/></spine></package>`)
	add("big.xhtml", "<html><body><p>"+strings.Repeat("a", mostEntry+10)+"</p></body></html>")
	writer.Close()
	file.Close()

	out := extractPath(t, Epub{}, path, "bomb.epub", "application/epub+zip", nil)

	if text := result[string](t, out, "text"); strings.Contains(text, "aaaa") || !strings.Contains(text, "Title: Bomb") {
		t.Fatalf("an oversized chapter was read: %d characters", len(text))
	}
}

func TestSheetsReadXlsx(t *testing.T) {
	for _, name := range []string{"budget.xlsx", "mislabelled.xls"} {
		t.Run(name, func(t *testing.T) {
			out := extracted(t, Sheets{}, name, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
			shapes := result[[]Shape](t, out, "sheets")
			tables := result[[]extract.Table](t, out, "tables")
			outline := result[[]SheetSection](t, out, "outline")
			text := result[string](t, out, "text")

			if len(shapes) != 2 || len(outline) != 2 || len(tables) == 0 {
				t.Fatalf("shapes %+v outline %+v tables %d", shapes, outline, len(tables))
			}

			if !strings.Contains(text, "SPREADSHEET-6194") {
				t.Fatalf("text lacks its needle:\n%s", text)
			}

			if tables[0].Columns[0] != "name" || len(tables[0].Rows) == 0 {
				t.Fatalf("table %+v", tables[0])
			}

			if got := string([]rune(text)[outline[1].From:]); !strings.HasPrefix(got, shapes[1].Name) {
				t.Fatalf("the second sheet starts at %q", extract.Truncate(got, 30))
			}
		})
	}
}

func TestSheetsKeepTextThatLooksNumeric(t *testing.T) {
	if got := cellOf("02134", "02134"); got != "02134" {
		t.Fatalf("%v", got)
	}

	if got := cellOf("1240", "1240"); got != int64(1240) {
		t.Fatalf("%v", got)
	}

	if got := cellOf("1/8/26", "46030"); got != "2026-01-08" {
		t.Fatalf("%v", got)
	}

	if got := cellOf("12%", "0.12"); got != 0.12 {
		t.Fatalf("%v", got)
	}
}

func TestSheetsReadOdsWithoutLibreOffice(t *testing.T) {
	lookSoffice = func(string) (string, error) { return "", os.ErrNotExist }
	defer func() { lookSoffice = exec.LookPath }()

	out := extracted(t, Sheets{}, "budget.ods", "application/vnd.oasis.opendocument.spreadsheet")
	tables := result[[]extract.Table](t, out, "tables")
	text := result[string](t, out, "text")

	if !strings.Contains(text, "SPREADSHEET-6194") {
		t.Fatalf("text %q", text)
	}

	if len(tables) == 0 || tables[0].Rows[0][1] != float64(1240) {
		t.Fatalf("tables %+v", tables)
	}
}

func TestSheetsBoundRepeatedOdsCells(t *testing.T) {
	path := filepath.Join(t.TempDir(), "repeat.ods")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}

	writer := zip.NewWriter(file)
	mimetype, _ := writer.Create("mimetype")
	mimetype.Write([]byte(ods))
	content, _ := writer.Create("content.xml")
	content.Write([]byte(`<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet><table:table table:name="Wide">` +
		`<table:table-row><table:table-cell office:value-type="string"><text:p>a</text:p></table:table-cell><table:table-cell office:value-type="string"><text:p>b</text:p></table:table-cell></table:table-row>` +
		`<table:table-row table:number-rows-repeated="1000000"><table:table-cell table:number-columns-repeated="16384"/></table:table-row>` +
		`<table:table-row table:number-rows-repeated="2000000000"><table:table-cell office:value-type="float" office:value="1" table:number-columns-repeated="2000000000"/></table:table-row>` +
		`</table:table></office:spreadsheet></office:body></office:document-content>`))
	writer.Close()
	file.Close()

	out := extractPath(t, Sheets{}, path, "repeat.ods", ods, nil)
	shapes := result[[]Shape](t, out, "sheets")

	if len(shapes) != 1 || shapes[0].Columns > mostColumns+1 || shapes[0].Rows > mostRows {
		t.Fatalf("shapes %+v", shapes)
	}
}

func TestMediaProbesMeasuresAndCutsAudio(t *testing.T) {
	needs(t, "ffmpeg", "ffprobe")

	out := extracted(t, Media{}, "tone.mp3", "audio/mpeg")
	probe := result[Probe](t, out, "probe")
	signal := result[Signal](t, out, "signal")

	if probe.Duration <= 0 || len(probe.Streams) == 0 || probe.Streams[0].Type != "audio" || probe.Tags["artist"] != "Bellwether" {
		t.Fatalf("probe %+v", probe)
	}

	if signal.Loudness == nil || signal.SilentThroughout {
		t.Fatalf("signal %+v", signal)
	}

	if len(out.Files) != 1 || out.Files[0].Role != "audio" {
		t.Fatalf("files %+v", out.Files)
	}

	header := make([]byte, 12)
	held, err := os.Open(out.Files[0].Path)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	held.Read(header)

	if string(header[:4]) != "RIFF" || string(header[8:12]) != "WAVE" {
		t.Fatalf("not a wav: %q", header)
	}
}

func TestMediaSamplesFramesFromVideo(t *testing.T) {
	needs(t, "ffmpeg", "ffprobe")

	out := extracted(t, Media{}, "clip.mp4", "video/mp4")
	frames := 0

	for _, file := range out.Files {
		if file.Role == "frame" {
			frames++

			if file.At == nil || file.MIME != "image/jpeg" {
				t.Fatalf("frame %+v", file)
			}
		}
	}

	if frames == 0 {
		t.Fatalf("no frames in %+v", out.Files)
	}

	skipped := extractPath(t, Media{}, mustAbs(t, "testdata/clip.mp4"), "clip.mp4", "video/mp4",
		map[string]bool{"scenes": true, "transcript": true})

	if len(skipped.Files) != 0 {
		t.Fatalf("skipped steps still made files: %+v", skipped.Files)
	}
}

func TestMediaMeasuresSilenceFromFfmpegOutput(t *testing.T) {
	said := "  I:         -23.5 LUFS\n  LRA:         4.2 LU\n    Peak:       -1.0 dBFS\nsilence_start: 1.5\nsilence_end: 2.75 | silence_duration: 1.25\nsilence_start: 9\n"
	found := measured(said, []string{"lavfi.aspectralstats.1.centroid=1200", "lavfi.aspectralstats.1.flatness=0.25"}, 10, 3600)

	if *found.Loudness != -23.5 || *found.Range != 4.2 || *found.Peak != -1 || found.Silent != 2.25 || *found.Centroid != 1200 {
		t.Fatalf("%+v", found)
	}

	if len(found.Silences) != 2 || found.Silences[1] != [2]float64{9, 10} || found.SilentThroughout {
		t.Fatalf("%+v", found.Silences)
	}
}

func mustAbs(t *testing.T, path string) string {
	held, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}

	return held
}
