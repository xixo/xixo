package extract

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestProfileOpensTheMacReaderItsFolderTheNeuralEngineAndCodecs(t *testing.T) {
	held, err := Profile("/work/extract-1", "/Users/someone/Library/Application Support/xixo-link/bin/xixo-mac-reader")
	if err != nil {
		t.Fatal(err)
	}

	for _, want := range []string{
		`(allow file-read* (literal "/Users/someone/Library/Application Support/xixo-link/bin/xixo-mac-reader"))`,
		`(allow file-read* (literal "/Users/someone/Library/Application Support/xixo-link/bin"))`,
		`"IOSurfaceRootUserClient" "AGXDeviceUserClient" "H11ANEInDirectPathClient"`,
		`(global-name "com.apple.appleneuralengine" "com.apple.audio.AudioComponentRegistrar")`,
	} {
		if !strings.Contains(held, want) {
			t.Errorf("the profile lacks %s:\n%s", want, held)
		}
	}

	for _, unwanted := range []string{"network", "audiohald", `(subpath "/Users/someone`, "pasteboard"} {
		if strings.Contains(held, unwanted) {
			t.Errorf("the profile holds %s:\n%s", unwanted, held)
		}
	}
}

func TestProfileOpensNothingForAProgramNamedLikeTheMacReaderWithoutAPath(t *testing.T) {
	held, err := Profile("/work/extract-1", MacReaderName)
	if err != nil {
		t.Fatal(err)
	}

	if strings.Contains(held, "iokit-open") || strings.Contains(held, "mach-lookup") {
		t.Fatalf("a bare name opened the reader's services:\n%s", held)
	}
}

type named struct {
	name  string
	needs []string
}

func (n named) Name() string                                  { return n.name }
func (named) Handles(string, string) bool                     { return false }
func (n named) Needs() []string                               { return n.needs }
func (named) Extract(context.Context, Input) (*Output, error) { return nil, nil }

func TestThePreferredUsableExtractorIsChosenForAName(t *testing.T) {
	missing := &named{name: "x", needs: []string{"no-such-program-anywhere"}}
	plain := &named{name: "x"}

	if chosen([]Extractor{missing, plain}) != plain {
		t.Fatal("an extractor that cannot run was chosen over one that can")
	}

	if chosen([]Extractor{missing}) != missing {
		t.Fatal("with none usable, the first was not kept")
	}

	if chosen(nil) != nil {
		t.Fatal("nothing registered chose something")
	}
}

func TestTextutilInfoReadsTheDocumentsFields(t *testing.T) {
	found := TextutilInfo("File:  note.doc\n  Type:  Word format\n  Size:  19456 bytes\n  Length:  88 characters\n" +
		"  Author:  Bea Okonkwo\n  Keywords:  shed, roof\n  Last Modified:  2002-12-09 20:26:00 +0000\n  Contents:  Shed notes...\n")

	want := Metadata{{"Author", "Bea Okonkwo"}, {"Keywords", "shed, roof"}, {"ModifyDate", "2002-12-09 20:26:00 +0000"}}
	if len(found) != len(want) {
		t.Fatalf("read %+v", found)
	}

	for at := range want {
		if found[at] != want[at] {
			t.Fatalf("read %+v", found)
		}
	}
}

func TestTextutilFormatFollowsTheTypeThenTheName(t *testing.T) {
	cases := map[[2]string]string{
		{"text/rtf", "a.txt"}:                 "rtf",
		{"application/octet-stream", "a.doc"}: "doc",
		{"application/x-webarchive", "page"}:  "webarchive",
		{"application/zip", "a.zip"}:          "",
	}

	for given, want := range cases {
		if got := TextutilFormat(given[0], given[1]); got != want {
			t.Errorf("%v gave %q", given, got)
		}
	}
}

func TestMacKindNamesWhatTheReaderDescribes(t *testing.T) {
	cases := map[string]string{"application/pdf": "pdf", "image/heic": "image", "audio/mpeg": "media", "video/mp4": "media", "application/zip": ""}

	for mime, want := range cases {
		if got := MacKind(mime); got != want {
			t.Errorf("%s gave %q", mime, got)
		}
	}
}

func TestMetadataWithoutExiftoolOrTheReaderSaysWhatIsMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	held := executable
	executable = func() (string, error) { return "", errors.New("no executable") }
	t.Cleanup(func() { executable = held })

	if _, err := MacMetadata(t.Context(), Input{MIME: "image/png", Path: "/work/a.png"}); !errors.Is(err, ErrNoMacReader) {
		t.Fatalf("got %v", err)
	}

	if _, err := MacMetadata(t.Context(), Input{MIME: "application/zip", Path: "/work/a.zip"}); !errors.Is(err, ErrNoExiftool) {
		t.Fatalf("got %v", err)
	}
}
