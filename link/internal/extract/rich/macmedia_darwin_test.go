package rich

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
)

func TestTheMacReaderHearsAPartFromTheMiddleOfALongRecording(t *testing.T) {
	built, err := filepath.Abs("../../../macos/build")
	if err != nil {
		t.Fatal(err)
	}

	t.Setenv("PATH", built+string(os.PathListSeparator)+os.Getenv("PATH"))

	if extract.MacReader() == "" {
		t.Skip("build the mac reader with make -C macos to run this")
	}

	needs(t, "ffmpeg")

	tone := filepath.Join(t.TempDir(), "tone.m4a")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=20", tone).CombinedOutput(); err != nil {
		t.Skipf("ffmpeg could not make a tone: %v %s", err, out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	out, err := MacMedia{}.Extract(ctx, extract.Input{
		Path: tone, Name: "tone.m4a", MIME: "audio/mp4", Work: t.TempDir(), Run: extract.Limited{},
		Set: extract.Settings{Transcribe: 12}, Skip: map[string]bool{"signal": true},
	})
	if err != nil {
		t.Fatal(err)
	}

	if len(out.Files) != 1 || out.Files[0].At == nil || *out.Files[0].At < 3 || *out.Files[0].At > 4 {
		t.Fatalf("files %+v", out.Files)
	}

	info, err := os.Stat(out.Files[0].Path)
	if err != nil || info.Size() < 44+11*32000 || info.Size() > 44+13*32000 {
		t.Fatalf("the part holds %d bytes: %v", info.Size(), err)
	}

	if !strings.Contains(out.Dropped["transcript"], "one part of 00:00:12") {
		t.Fatalf("dropped %v", out.Dropped)
	}
}
