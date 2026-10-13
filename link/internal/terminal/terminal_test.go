package terminal

import (
	"bytes"
	"os"
	"testing"
)

func TestOnlyATerminalGetsColor(t *testing.T) {
	if For(&bytes.Buffer{}).On {
		t.Fatal("a buffer got color")
	}

	file, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	if For(file).On {
		t.Fatal("a file got color")
	}

	if got := (Style{}).Bold("media"); got != "media" {
		t.Fatalf("plain bold gave %q", got)
	}

	if got := (Style{On: true}).Bold("media"); got != "\x1b[1mmedia\x1b[0m" {
		t.Fatalf("bold gave %q", got)
	}
}

func TestNoColorTurnsColorOff(t *testing.T) {
	t.Setenv("NO_COLOR", "1")

	if For(os.Stdout).On {
		t.Fatal("NO_COLOR left color on")
	}
}

func TestPrintableDropsWhatCouldDriveATerminal(t *testing.T) {
	if got := Printable("media\x1b]8;;https://evil\x07‮\nbox"); got != "media]8;;https://evilbox" {
		t.Fatalf("got %q", got)
	}
}
