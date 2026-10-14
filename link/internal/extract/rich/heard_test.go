package rich

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
)

func TestPartsCoverAShortRecordingAndSpreadALongOne(t *testing.T) {
	cases := []struct {
		name     string
		duration float64
		span     int
		want     []Part
	}{
		{"a song", 215.4, 3600, []Part{{From: 0, Seconds: 216}}},
		{"a podcast", 1500, 3600, []Part{{From: 0, Seconds: 600}, {From: 600, Seconds: 600}, {From: 1200, Seconds: 300}}},
		{"an unknown length", 0, 3600, []Part{{From: 0, Seconds: 3600}}},
		{"a 2.5-hour film", 9000, 3600, []Part{
			{From: 450, Seconds: 600}, {From: 1950, Seconds: 600}, {From: 3450, Seconds: 600},
			{From: 4950, Seconds: 600}, {From: 6450, Seconds: 600}, {From: 7950, Seconds: 600},
		}},
		{"a short span", 20, 12, []Part{{From: 4, Seconds: 12}}},
	}

	for _, held := range cases {
		if got := Parts(held.duration, held.span); !reflect.DeepEqual(got, held.want) {
			t.Errorf("%s: %+v", held.name, got)
		}
	}

	heard := 0
	for _, part := range Parts(4*3600, extract.MostTranscribe) {
		heard += part.Seconds
	}

	if heard > extract.MostTranscribe {
		t.Fatalf("a four-hour recording heard %d seconds", heard)
	}
}

func TestMediaHearsAPartFromTheMiddleOfALongRecording(t *testing.T) {
	needs(t, "ffmpeg", "ffprobe")

	dir := t.TempDir()
	tone := filepath.Join(dir, "tone.m4a")

	made := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=20", tone)
	if out, err := made.CombinedOutput(); err != nil {
		t.Skipf("ffmpeg could not make a tone: %v %s", err, out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	out, err := Media{}.Extract(ctx, extract.Input{
		Path: tone, Name: "tone.m4a", MIME: "audio/mp4", Work: t.TempDir(), Run: extract.Limited{},
		Set: extract.Settings{Transcribe: 12}, Skip: map[string]bool{"signal": true},
	})
	if err != nil {
		t.Fatal(err)
	}

	if len(out.Files) != 1 || out.Files[0].Role != "audio" || out.Files[0].At == nil || *out.Files[0].At < 3 || *out.Files[0].At > 4 {
		t.Fatalf("files %+v", out.Files)
	}

	info, err := os.Stat(out.Files[0].Path)
	if err != nil || info.Size() < 44+11*32000 || info.Size() > 44+13*32000 {
		t.Fatalf("the part holds %d bytes: %v", info.Size(), err)
	}

	if !strings.Contains(out.Dropped["transcript"], "one part of 00:00:12, from the middle of 00:00:20") {
		t.Fatalf("dropped %v", out.Dropped)
	}
}
