package extract

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const corpus = "../../../test/fixtures/corpus"

func needs(t *testing.T, programs ...string) {
	t.Helper()

	for _, program := range programs {
		if _, err := exec.LookPath(program); err != nil {
			t.Skipf("%s is not installed", program)
		}
	}
}

func corpusFile(t *testing.T, name string) string {
	t.Helper()

	path := filepath.Join(corpus, name)
	if _, err := os.Stat(path); err != nil {
		t.Skip("the corpus is not checked out")
	}

	return path
}

func common(t *testing.T, name, mime string) *Output {
	t.Helper()

	path := corpusFile(t, name)
	out := &Output{}

	err := Common(context.Background(), Input{
		Path: path, Name: filepath.Base(path), MIME: mime, Work: t.TempDir(), Run: Limited{},
		Set: Settings{Thumbnail: 160, Preview: 1024},
	}, out)
	if err != nil {
		t.Fatal(err)
	}

	return out
}

func TestMetadataLeavesThePlumbingOut(t *testing.T) {
	needs(t, "exiftool")

	out := common(t, "image/photo.jpg", "image/jpeg")
	if out.Steps["metadata"].Error != "" {
		t.Fatal(out.Steps["metadata"].Error)
	}

	encoded, err := json.Marshal(out.Steps["metadata"].Result)
	if err != nil {
		t.Fatal(err)
	}

	held := map[string]any{}
	if err := json.Unmarshal(encoded, &held); err != nil {
		t.Fatal(err)
	}

	if len(held) == 0 {
		t.Fatal("no tags")
	}

	for _, plumbing := range []string{"SourceFile", "ExifToolVersion", "FileName", "Directory", "XResolution"} {
		if _, ok := held[plumbing]; ok {
			t.Fatalf("%s should be left out: %v", plumbing, held)
		}
	}
}

func TestEveryRenderableKindGetsAThumbnailAndAPreview(t *testing.T) {
	cases := map[string][]string{
		"image/photo.jpg":    {"image/jpeg", "vipsthumbnail"},
		"image/photo.nef":    {"image/x-dcraw", "vipsthumbnail", "simple_dcraw", "vipsheader"},
		"pdf/invoice.pdf":    {"application/pdf", "pdftoppm"},
		"other/clip.mp4":     {"video/mp4", "ffmpeg", "vipsthumbnail"},
		"other/tone.mp3":     {"audio/mpeg", "ffmpeg", "ffprobe"},
		"image/animated.gif": {"image/gif", "vipsthumbnail"},
	}

	for name, held := range cases {
		t.Run(name, func(t *testing.T) {
			needs(t, held[1:]...)

			out := common(t, name, held[0])
			if out.Steps["derived"].Error != "" {
				t.Fatal(out.Steps["derived"].Error)
			}

			if len(out.Files) != 2 {
				t.Fatalf("files %+v", out.Files)
			}

			for _, file := range out.Files {
				info, err := os.Stat(file.Path)
				if err != nil || info.Size() == 0 {
					t.Fatalf("%s is empty", file.Role)
				}
			}
		})
	}
}

func TestARenderedImageCarriesNoneOfTheOriginalsMetadata(t *testing.T) {
	needs(t, "vipsthumbnail", "vipsheader")

	photo, err := os.ReadFile(corpusFile(t, "image/photo.jpg"))
	if err != nil {
		t.Fatal(err)
	}

	tiff := []byte("MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x0e\x00\x02\x00\x00\x00\x07\x00\x00\x00\x1a\x00\x00\x00\x00SECRET\x00")
	app1 := append([]byte("Exif\x00\x00"), tiff...)
	segment := append([]byte{0xFF, 0xE1, byte((len(app1) + 2) >> 8), byte(len(app1) + 2)}, app1...)
	tagged := filepath.Join(t.TempDir(), "tagged.jpg")

	if err := os.WriteFile(tagged, append(append(photo[:2:2], segment...), photo[2:]...), 0o600); err != nil {
		t.Fatal(err)
	}

	before, _ := Limited{}.Run(context.Background(), 0, "vipsheader", "-a", tagged)
	if !strings.Contains(string(before), "SECRET") {
		t.Fatalf("the source carries no metadata to strip: %s", before)
	}

	out := &Output{}
	if err := Common(context.Background(), Input{
		Path: tagged, Name: "tagged.jpg", MIME: JPEG, Work: t.TempDir(), Run: Limited{},
		Set: Settings{Thumbnail: 160, Preview: 1024},
	}, out); err != nil {
		t.Fatal(err)
	}

	if len(out.Files) != 2 {
		t.Fatalf("files %+v", out.Files)
	}

	for _, file := range out.Files {
		held, err := Limited{}.Run(context.Background(), 0, "vipsheader", "-a", file.Path)
		if err != nil {
			t.Fatal(err)
		}

		if strings.Contains(string(held), "exif") || strings.Contains(string(held), "SECRET") {
			t.Fatalf("the %s kept the original's metadata: %s", file.Role, held)
		}
	}
}

func TestARawGetsItsFullPreviewAndNotItsHeaderThumbnail(t *testing.T) {
	needs(t, "simple_dcraw", "vipsheader", "vipsthumbnail")

	out := common(t, "image/photo.nef", "image/x-dcraw")

	for _, file := range out.Files {
		if file.Role != Preview {
			continue
		}

		longest := 0

		for _, edge := range []string{"width", "height"} {
			held, err := Limited{}.Run(context.Background(), 0, "vipsheader", "-f", edge, file.Path)
			if err != nil {
				t.Fatal(err)
			}

			measured, _ := strconv.Atoi(strings.TrimSpace(string(held)))
			longest = max(longest, measured)
		}

		if longest != 1024 {
			t.Fatalf("the preview's longest edge is %d", longest)
		}
	}
}
