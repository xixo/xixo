package extract_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/extract/documents"
	_ "github.com/xixo/xixo/link/internal/extract/plain"
	_ "github.com/xixo/xixo/link/internal/extract/rich"
)

var routed = []string{"pdf", "image", "media", "doc", "epub", "xlsx", "calendar", "pkpass", "email", "contact", "data", "text", "fallback"}

func bareMac(t *testing.T) {
	t.Helper()

	built, err := filepath.Abs("../../macos/build")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(built, extract.MacReaderName)); err != nil {
		t.Skip("build the mac reader with make -C macos to run these")
	}

	t.Setenv("PATH", strings.Join([]string{"/usr/bin", "/bin", "/usr/sbin", "/sbin", built}, string(os.PathListSeparator)))
}

func extracted(t *testing.T, from, mime string) *extract.Output {
	t.Helper()

	confine, err := extract.Sandbox()
	if err != nil {
		t.Skip(err)
	}

	work, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(from)
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(work, "source"+filepath.Ext(from))
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	out, err := extract.Run(context.Background(), extract.Input{
		Path: path,
		Name: filepath.Base(from),
		MIME: mime,
		Size: int64(len(raw)),
		Skip: map[string]bool{},
		Work: work,
		Run:  extract.Within(extract.Limited{Confine: confine}, work, 1<<30),
	})
	if err != nil {
		t.Fatal(err)
	}

	return out
}

func result(t *testing.T, out *extract.Output, step string) any {
	t.Helper()

	held, ok := out.Steps[step]
	if !ok {
		t.Fatalf("no %s step in %+v", step, out.Steps)
	}

	if held.Error != "" {
		t.Fatalf("%s failed: %s", step, held.Error)
	}

	body, _ := json.Marshal(held.Result)
	var plain any
	json.Unmarshal(body, &plain)

	return plain
}

func said(t *testing.T, out *extract.Output, step string) string {
	t.Helper()

	text, _ := result(t, out, step).(string)

	return text
}

func jpegs(t *testing.T, out *extract.Output, role string) int {
	t.Helper()

	count := 0

	for _, file := range out.Files {
		if file.Role != role {
			continue
		}

		raw, err := os.ReadFile(file.Path)
		if err != nil || !bytes.HasPrefix(raw, []byte{0xff, 0xd8, 0xff}) {
			t.Fatalf("%s %s is not a JPEG: %v", role, file.Name, err)
		}

		count++
	}

	return count
}

func TestABareMacOffersEveryExtractorTheServerRoutesTo(t *testing.T) {
	bareMac(t)

	if extract.Present("exiftool") || extract.Present("ffmpeg") || extract.Present("pdftotext") {
		t.Fatal("the bare PATH still finds Homebrew")
	}

	for _, name := range routed {
		if !slices.Contains(extract.Available(), name) {
			t.Errorf("a bare Mac lacks the %s extractor: %v", name, extract.Available())
		}
	}
}

func TestABareMacReadsPDFs(t *testing.T) {
	bareMac(t)

	out := extracted(t, "documents/testdata/report.pdf", "application/pdf")
	if text := said(t, out, "text"); !strings.Contains(text, "PDFREPORT-7715") || !strings.Contains(text, "\f") {
		t.Fatalf("the pdf read %q", text)
	}

	if info := result(t, out, "info").(map[string]any); info["pages"] != 5.0 {
		t.Fatalf("info %+v", info)
	}

	if tags := result(t, out, "metadata").(map[string]any); tags["PageCount"] != 5.0 {
		t.Fatalf("metadata %+v", tags)
	}

	if jpegs(t, out, "thumbnail") != 1 || jpegs(t, out, "preview") != 1 {
		t.Fatalf("files %+v", out.Files)
	}

	scanned := extracted(t, "documents/testdata/scanned.pdf", "application/pdf")
	if text := said(t, scanned, "text"); !strings.Contains(text, "OCRRECEIPT-9042") {
		t.Fatalf("vision read %q from the scan", text)
	}
}

func TestABareMacReadsImages(t *testing.T) {
	bareMac(t)

	receipt := extracted(t, "documents/testdata/ocr-receipt.png", "image/png")
	if text := said(t, receipt, "ocr"); !strings.Contains(text, "OCRRECEIPT-9042") {
		t.Fatalf("vision read %q", text)
	}

	if size := result(t, receipt, "dimensions").(map[string]any); size["width"] != 1000.0 || size["height"] != 700.0 {
		t.Fatalf("dimensions %+v", size)
	}

	photo := extracted(t, "documents/testdata/photo.heic", "image/heic")
	if spread := result(t, photo, "deviation").(float64); spread < 1 {
		t.Fatalf("deviation %v", spread)
	}

	if jpegs(t, photo, "thumbnail") != 1 || jpegs(t, photo, "preview") != 1 {
		t.Fatalf("files %+v", photo.Files)
	}

	if tags := result(t, photo, "metadata").(map[string]any); tags["ImageSize"] == nil {
		t.Fatalf("metadata %+v", tags)
	}

	animated := extracted(t, "documents/testdata/animated.gif", "image/gif")
	if frames := result(t, animated, "frames"); frames != 3.0 || jpegs(t, animated, "frame") != 3 {
		t.Fatalf("frames %v, files %+v", frames, animated.Files)
	}
}

func TestABareMacReadsDocuments(t *testing.T) {
	bareMac(t)

	docx := extracted(t, "documents/testdata/report.docx", documents.Docx)
	if docx.Extractor != "doc" || !strings.Contains(said(t, docx, "text"), "Needle") {
		t.Fatalf("the docx read %+v", docx.Steps)
	}

	dir := t.TempDir()
	rtf := filepath.Join(dir, "note.rtf")
	if err := os.WriteFile(rtf, []byte(`{\rtf1\ansi{\info{\author Bea Okonkwo}}Needle: RTF-3318\par}`), 0o600); err != nil {
		t.Fatal(err)
	}

	read := extracted(t, rtf, "text/rtf")
	if read.Extractor != "doc" || said(t, read, "text") != "Needle: RTF-3318" {
		t.Fatalf("the rtf read %+v", read.Steps)
	}

	if info := result(t, read, "info").(map[string]any); info["author"] != "Bea Okonkwo" {
		t.Fatalf("info %+v", info)
	}

	epub := extracted(t, "rich/testdata/book.epub", "application/epub+zip")
	if epub.Steps["metadata"].Error != extract.ErrNoExiftool.Error() {
		t.Fatalf("an epub's metadata said %+v", epub.Steps["metadata"])
	}
}

func TestABareMacReadsAudioAndVideo(t *testing.T) {
	bareMac(t)

	tone := extracted(t, "rich/testdata/tone.mp3", "audio/mpeg")
	probe := result(t, tone, "probe").(map[string]any)
	if probe["duration"].(float64) < 1 || probe["title"] == nil {
		t.Fatalf("probe %+v", probe)
	}

	if signal := result(t, tone, "signal").(map[string]any); signal["loudness"] == nil || signal["silent_throughout"] != false {
		t.Fatalf("signal %+v", signal)
	}

	if jpegs(t, tone, "thumbnail") != 1 {
		t.Fatalf("files %+v", tone.Files)
	}

	var heard []byte
	for _, file := range tone.Files {
		if file.Role == "audio" {
			heard, _ = os.ReadFile(file.Path)
		}
	}

	if len(heard) < 44 || string(heard[:4]) != "RIFF" || string(heard[8:12]) != "WAVE" || heard[24] != 0x80 || heard[25] != 0x3e {
		t.Fatalf("heard.wav is not 16 kHz WAV: % x", heard[:min(len(heard), 44)])
	}

	clip := extracted(t, "rich/testdata/clip-sound.mp4", "video/mp4")
	if jpegs(t, clip, "frame") != 1 || jpegs(t, clip, "thumbnail") != 1 {
		t.Fatalf("files %+v", clip.Files)
	}

	if _, ok := clip.Steps["signal"]; !ok {
		t.Fatalf("steps %+v", clip.Steps)
	}
}
