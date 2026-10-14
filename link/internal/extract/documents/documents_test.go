package documents

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
)

type scriptedRunner struct {
	answers map[string]string
	calls   []string
}

func (r *scriptedRunner) Run(_ context.Context, _ time.Duration, program string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, program)
	said, ok := r.answers[program]
	if !ok {
		return nil, fmt.Errorf("%s is not scripted", program)
	}
	return []byte(said), nil
}

func (r *scriptedRunner) RunTo(ctx context.Context, limit time.Duration, stdout io.Writer, program string, args ...string) error {
	said, err := r.Run(ctx, limit, program, args...)
	stdout.Write(said)
	return err
}

func needs(t *testing.T, programs ...string) {
	t.Helper()
	for _, program := range programs {
		if _, err := exec.LookPath(program); err != nil {
			t.Skipf("%s is not installed here; run these tests in a Linux image with the extraction programs", program)
		}
	}
}

func input(t *testing.T, name, mime string) extract.Input {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return extract.Input{Path: path, Name: name, MIME: mime, Work: t.TempDir(), Run: extract.Limited{}}
}

func text(out *extract.Output, step string) string {
	said, _ := out.Steps[step].Result.(string)
	return said
}

func TestParseInfoKeepsTheFieldsXixoReads(t *testing.T) {
	said := "Title:          Invoice 2026-114\nAuthor:         Bellwether Surveying\nCreator:        Writer\nPages:          5\nPage size:      595 x 842 pts (A4)\nCreationDate:   Sat Mar 14 09:30:00 2026 UTC\nnot a field\n"
	want := map[string]any{
		"title":        "Invoice 2026-114",
		"author":       "Bellwether Surveying",
		"pages":        5,
		"page_size":    "595 x 842 pts (A4)",
		"creationdate": "Sat Mar 14 09:30:00 2026 UTC",
	}
	if got := ParseInfo(said); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v", got)
	}
}

func TestSparseCountsVisibleCharactersPerPage(t *testing.T) {
	if !sparse(strings.Repeat("a ", 39), 1) {
		t.Fatal("39 characters on one page is sparse")
	}
	if sparse(strings.Repeat("a", 40), 1) {
		t.Fatal("40 characters on one page is not sparse")
	}
	if !sparse(strings.Repeat("a", 100), 3) {
		t.Fatal("100 characters across three pages is sparse")
	}
	if !sparse("", 0) {
		t.Fatal("no text is sparse")
	}
}

func TestCappedTruncatesAndSaysWhatWasLeft(t *testing.T) {
	s := begin(context.Background(), extract.Input{}, "pdf")
	long := strings.Repeat("é", MaxText+5)
	got := s.capped(long)
	if n := len([]rune(got)); n != MaxText {
		t.Fatalf("kept %d characters", n)
	}
	if !strings.HasSuffix(got, "...") {
		t.Fatal("no omission mark")
	}
	if s.out.Dropped["text"] != "only the first 200,000 of 200,005 characters were read" {
		t.Fatalf("dropped %q", s.out.Dropped["text"])
	}
	if short := s.capped("short"); short != "short" {
		t.Fatalf("short text changed to %q", short)
	}
}

func TestPickedSpreadsFramesLikeTheSettingsSay(t *testing.T) {
	cases := []struct {
		frames, most, share int
		want                []int
	}{
		{3, 4, 100, []int{0, 1, 2}},
		{100, 4, 100, []int{0, 25, 50, 75}},
		{8, 12, 10, []int{0}},
		{8, 12, 50, []int{0, 2, 4, 6}},
		{0, 4, 100, nil},
	}
	for _, c := range cases {
		if got := Picked(c.frames, c.most, c.share); !reflect.DeepEqual(got, c.want) {
			t.Errorf("Picked(%d, %d, %d) = %v, want %v", c.frames, c.most, c.share, got, c.want)
		}
	}
}

func TestPdfOcrsOnlyWhenTheTextLayerIsSparse(t *testing.T) {
	runner := &scriptedRunner{answers: map[string]string{
		"pdfinfo":   "Pages: 1\n",
		"pdftotext": strings.Repeat("plenty of text ", 10),
	}}
	in := extract.Input{Path: "x.pdf", Name: "x.pdf", MIME: "application/pdf", Work: t.TempDir(), Run: runner}
	out, err := Pdf{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(text(out, "text"), "plenty of text") {
		t.Fatalf("text %q", text(out, "text"))
	}
	for _, call := range runner.calls {
		if call == "pdftoppm" || call == "tesseract" {
			t.Fatalf("ran %s on a pdf with a text layer", call)
		}
	}
}

func TestPdfSkipsStepsXixoAlreadyHolds(t *testing.T) {
	runner := &scriptedRunner{answers: map[string]string{"pdfinfo": "Pages: 1\n"}}
	in := extract.Input{Path: "x.pdf", Name: "x.pdf", MIME: "application/pdf", Work: t.TempDir(), Run: runner, Skip: map[string]bool{"text": true}}
	out, err := Pdf{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if _, ran := out.Steps["text"]; ran {
		t.Fatal("text ran though it was skipped")
	}
}

func TestPdfCorpus(t *testing.T) {
	needs(t, "pdfinfo", "pdftotext", "pdftoppm", "tesseract")
	cases := map[string]string{
		"invoice.pdf":     "PDFINVOICE-4820",
		"report.pdf":      "PDFREPORT-7715",
		"no-metadata.pdf": "PDFNOMETA-5561",
		"scanned.pdf":     "OCRRECEIPT-9042",
	}
	for name, needle := range cases {
		out, err := Pdf{}.Extract(context.Background(), input(t, name, "application/pdf"))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !strings.Contains(text(out, "text"), needle) {
			t.Errorf("%s text lost %s: %q", name, needle, text(out, "text"))
		}
		if out.Steps["info"].Error != "" {
			t.Errorf("%s info failed: %s", name, out.Steps["info"].Error)
		}
	}

	out, _ := Pdf{}.Extract(context.Background(), input(t, "invoice.pdf", "application/pdf"))
	if want := goldenText(t, "pdf", "invoice.pdf", "text"); text(out, "text") != want {
		t.Errorf("invoice text differs from what Ruby read\n got %q\nwant %q", text(out, "text"), want)
	}
	info := out.Steps["info"].Result.(map[string]any)
	if info["title"] != "Invoice 2026-114" || info["pages"] != 1 {
		t.Errorf("invoice info %#v", info)
	}
}

func TestPdfThatIsBrokenStillAnswers(t *testing.T) {
	needs(t, "pdfinfo", "pdftotext", "pdftoppm", "tesseract")
	for _, name := range []string{"truncated.pdf", "not-a-pdf.pdf", "empty-page.pdf"} {
		out, err := Pdf{}.Extract(context.Background(), input(t, name, "application/pdf"))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if _, ok := out.Steps["text"]; !ok {
			t.Errorf("%s has no text step", name)
		}
	}
}

func TestDocCorpus(t *testing.T) {
	needs(t, "soffice", "pdfinfo", "pdftotext")
	for name, mime := range map[string]string{"report.docx": Docx, "report.odt": Odt} {
		out, err := Doc{}.Extract(context.Background(), input(t, name, mime))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if want := goldenText(t, "doc", name, "text"); text(out, "text") != want {
			t.Errorf("%s\n got %q\nwant %q", name, text(out, "text"), want)
		}
		info, _ := out.Steps["info"].Result.(map[string]any)
		if info["pages"] != 1 {
			t.Errorf("%s info %#v %s", name, info, out.Steps["info"].Error)
		}
	}
}

func TestDocFallsBackToThePdfsText(t *testing.T) {
	needs(t, "soffice", "pdfinfo", "pdftotext")
	dir := t.TempDir()
	source := filepath.Join(dir, "letter.html")
	if err := os.WriteFile(source, []byte("<html><body><p>Needle: DOCPDF-3301</p></body></html>"), 0o600); err != nil {
		t.Fatal(err)
	}
	in := extract.Input{Path: source, Name: "letter.doc", MIME: "application/msword", Work: t.TempDir(), Run: extract.Limited{}}
	out, err := Doc{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text(out, "text"), "DOCPDF-3301") {
		t.Fatalf("text %q (%s)", text(out, "text"), out.Steps["text"].Error)
	}
}

func TestImageCorpus(t *testing.T) {
	needs(t, "vipsheader", "vips", "exiftool", "tesseract")
	cases := []struct {
		name, mime, needle string
	}{
		{"ocr-receipt.png", "image/png", "OCRRECEIPT-9042"},
		{"photo.png", "image/png", "PHOTO-BELLWETHER-8123"},
		{"photo.heic", "image/heic", "PHOTO-BELLWETHER"},
		{"exif-rotated.jpg", "image/jpeg", ""},
		{"picture.webp", "image/webp", ""},
		{"icon.ico", "image/vnd.microsoft.icon", ""},
		{"truncated.png", "image/png", ""},
	}
	for _, c := range cases {
		out, err := Image{}.Extract(context.Background(), input(t, c.name, c.mime))
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		steps := golden(t, "image", c.name)["steps"].(map[string]any)
		wantDims := steps["dimensions"].(map[string]any)["result"].(map[string]any)
		dims, _ := out.Steps["dimensions"].Result.(map[string]int)
		if float64(dims["width"]) != wantDims["width"].(float64) || float64(dims["height"]) != wantDims["height"].(float64) {
			t.Errorf("%s dimensions %v, Ruby read %v", c.name, dims, wantDims)
		}
		if spread, _ := out.Steps["deviation"].Result.(float64); spread <= 1 || spread > 255 {
			t.Errorf("%s deviation %v is not on the 8-bit scale", c.name, spread)
		}
		if c.needle != "" && !strings.Contains(text(out, "ocr"), c.needle) {
			t.Errorf("%s ocr lost %s: %q (%s)", c.name, c.needle, text(out, "ocr"), out.Steps["ocr"].Error)
		}
		if loc := out.Steps["location"]; loc.Digest != LocatedBy || !reflect.ValueOf(loc.Result).IsNil() {
			t.Errorf("%s location %#v", c.name, loc)
		}
	}
}

func TestStillWebpIsOneFrame(t *testing.T) {
	needs(t, "vipsheader", "vips", "exiftool", "tesseract")
	out, err := Image{}.Extract(context.Background(), input(t, "picture.webp", "image/webp"))
	if err != nil {
		t.Fatal(err)
	}
	if step := out.Steps["frames"]; step.Result != 1 || step.Error != "" {
		t.Fatalf("frames %#v", step)
	}
	if len(out.Files) != 0 {
		t.Fatalf("a still image sent %d frames", len(out.Files))
	}
}

func TestAnimationSendsSampledFrames(t *testing.T) {
	needs(t, "vipsheader", "vips", "exiftool", "tesseract")
	in := input(t, "animated.gif", "image/gif")
	out, err := Image{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if out.Steps["frames"].Result != 3 {
		t.Fatalf("frames %#v", out.Steps["frames"])
	}
	var names []string
	for _, f := range out.Files {
		if f.Role != "frame" || f.MIME != "image/jpeg" {
			t.Errorf("file %#v", f)
		}
		if !strings.HasPrefix(f.Path, in.Work) {
			t.Errorf("frame %s is outside the work dir", f.Path)
		}
		if info, err := os.Stat(f.Path); err != nil || info.Size() == 0 {
			t.Errorf("frame %s is missing or empty", f.Path)
		}
		names = append(names, f.Name)
	}
	if want := []string{"frame-0.jpg", "frame-1.jpg", "frame-2.jpg"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("frames %v", names)
	}

	in = input(t, "animated.gif", "image/gif")
	in.Set = extract.Settings{Frames: 1}
	out, _ = Image{}.Extract(context.Background(), in)
	if len(out.Files) != 1 {
		t.Fatalf("one frame asked for, %d sent", len(out.Files))
	}
}

func TestLocationComesFromGPSTags(t *testing.T) {
	needs(t, "vipsheader", "vips", "exiftool", "tesseract")
	dir := t.TempDir()
	photo := filepath.Join(dir, "located.jpg")
	original, err := os.ReadFile(filepath.Join("testdata", "photo.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(photo, original, 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("exiftool", "-overwrite_original", "-GPSLatitude=51.5203", "-GPSLatitudeRef=N",
		"-GPSLongitude=0.0987654", "-GPSLongitudeRef=W", photo).CombinedOutput(); err != nil {
		t.Fatalf("exiftool: %v %s", err, out)
	}
	in := extract.Input{Path: photo, Name: "located.jpg", MIME: "image/jpeg", Work: t.TempDir(), Run: extract.Limited{}}
	out, err := Image{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]float64{"latitude": 51.5203, "longitude": -0.098765}
	if got := out.Steps["location"].Result; !reflect.DeepEqual(got, want) {
		t.Fatalf("location %#v", got)
	}
}

func TestRawIsDevelopedBeforeItIsRead(t *testing.T) {
	needs(t, "vipsheader", "vips", "exiftool", "tesseract", "simple_dcraw")
	corpus := os.Getenv("XIXO_CORPUS")
	if corpus == "" {
		t.Skip("XIXO_CORPUS names the corpus directory holding image/photo.nef")
	}
	path := filepath.Join(corpus, "image", "photo.nef")
	if _, err := os.Stat(path); err != nil {
		t.Skip("no photo.nef in XIXO_CORPUS")
	}
	in := extract.Input{Path: path, Name: "photo.nef", MIME: RawImageMIME, Work: t.TempDir(), Run: extract.Limited{}}
	out, err := Image{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	dims, _ := out.Steps["dimensions"].Result.(map[string]int)
	if dims["width"] < RawMinimum {
		t.Fatalf("raw read at %v, the header thumbnail rather than the photograph", dims)
	}
	leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(path), "photo.nef.*"))
	if len(leftovers) > 0 {
		t.Fatalf("developing wrote beside the original: %v", leftovers)
	}
}

func TestEveryExtractorIsRegisteredByItsRubyName(t *testing.T) {
	for _, e := range []extract.Extractor{Pdf{}, Doc{}, Image{}} {
		if len(e.Needs()) == 0 {
			t.Errorf("%s needs no programs", e.Name())
		}
	}
	if !(Image{}).Handles(RawImageMIME, "photo.nef") || (Pdf{}).Handles("image/png", "x.png") {
		t.Fatal("handles the wrong types")
	}
	if !(Doc{}).Handles("application/msword", "x.doc") || (Doc{}).Handles("text/plain", "x.txt") {
		t.Fatal("doc handles the wrong types")
	}
	if !IsRaw("PHOTO.NEF") || IsRaw("photo.jpg") {
		t.Fatal("raw detection is wrong")
	}
}

func TestRawThatWillNotDevelopStillHasItsTaggedSize(t *testing.T) {
	source := filepath.Join(t.TempDir(), "upload")
	if err := os.WriteFile(source, []byte("not really a raw"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := &scriptedRunner{answers: map[string]string{
		"exiftool": `[{"ImageWidth": 6016, "ImageHeight": 4016}]`,
	}}
	in := extract.Input{Path: source, Name: "shot.nef", MIME: "image/x-nikon-nef", Work: t.TempDir(), Run: runner}
	out, err := Image{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	step := out.Steps["dimensions"]
	if step.Error != "" || !reflect.DeepEqual(step.Result, map[string]int{"width": 6016, "height": 4016}) {
		t.Fatalf("dimensions %#v %q", step.Result, step.Error)
	}
	if _, ok := out.Steps["location"]; !ok {
		t.Fatal("an undeveloped raw lost its location step")
	}
}

func TestOnePixelHasNoSpread(t *testing.T) {
	needs(t, "vips", "vipsheader")
	dir := t.TempDir()
	pixel := filepath.Join(dir, "pixel.png")
	if said, err := exec.Command("vips", "black", pixel, "1", "1").CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, said)
	}
	in := extract.Input{Path: pixel, Name: "pixel.png", MIME: "image/png", Work: t.TempDir(), Run: extract.Limited{}}
	out, err := Image{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	step := out.Steps["deviation"]
	if step.Error != "" || step.Result != 0.0 {
		t.Fatalf("deviation %#v %q", step.Result, step.Error)
	}
}

func TestZip64OfficeFilesKeepTheirMetadata(t *testing.T) {
	needs(t, "exiftool")
	for name, mime := range map[string]string{"report.docx": Docx, "report.odt": Odt} {
		in := input(t, name, mime)
		out := &extract.Output{}
		if err := extract.Common(context.Background(), in, out); err != nil {
			t.Fatal(err)
		}
		if step := out.Steps["metadata"]; step.Error != "" {
			t.Errorf("%s metadata %q", name, step.Error)
		}
	}
}

func TestDocReadsAnUploadWithoutAnExtension(t *testing.T) {
	needs(t, "soffice", "pdfinfo", "pdftotext")
	original, err := os.ReadFile(filepath.Join("testdata", "report.odt"))
	if err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(t.TempDir(), "upload")
	if err := os.WriteFile(source, original, 0o600); err != nil {
		t.Fatal(err)
	}
	in := extract.Input{Path: source, Name: "report.odt", MIME: Odt, Work: t.TempDir(), Run: extract.Limited{}}
	out, err := Doc{}.Extract(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if info, _ := out.Steps["info"].Result.(map[string]any); info["pages"] != 1 {
		t.Fatalf("info %#v %q", out.Steps["info"].Result, out.Steps["info"].Error)
	}
}

func TestAnOfficeDocumentIsCopiedAndAPDFIsReadWhereItLies(t *testing.T) {
	if !extract.Copies("application/msword", "a.doc") {
		t.Fatal("a Word file is read in place, where LibreOffice may write beside it")
	}

	if extract.Copies("application/pdf", "a.pdf") {
		t.Fatal("a PDF is copied")
	}
}
