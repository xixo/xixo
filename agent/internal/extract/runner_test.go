package extract

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestLimitedRunsAProgram(t *testing.T) {
	out, err := Limited{}.Run(context.Background(), 5*time.Second, "echo", "hello")
	if err != nil {
		t.Fatal(err)
	}

	if strings.TrimSpace(string(out)) != "hello" {
		t.Fatalf("got %q", out)
	}
}

func TestLimitedStopsAProgramPastItsDeadline(t *testing.T) {
	started := time.Now()

	_, err := Limited{}.Run(context.Background(), 200*time.Millisecond, "sh", "-c", "sleep 30 & sleep 30")
	if !errors.Is(err, ErrStopped) {
		t.Fatalf("got %v", err)
	}

	if time.Since(started) > 5*time.Second {
		t.Fatal("the program outlived its deadline")
	}
}

func TestLimitedCapsMemory(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("only Linux honors a data limit")
	}

	out, err := Limited{Memory: 64 << 20}.Run(context.Background(), 5*time.Second, "sh", "-c", "ulimit -d")
	if err != nil {
		t.Fatal(err)
	}

	if strings.TrimSpace(string(out)) != "65536" {
		t.Fatalf("the data limit is %q", out)
	}
}

func TestLimitedReportsAFailure(t *testing.T) {
	_, err := Limited{}.Run(context.Background(), 5*time.Second, "sh", "-c", "echo broken >&2; exit 3")
	if err == nil || !strings.Contains(err.Error(), "broken") {
		t.Fatalf("got %v", err)
	}
}

func TestExiftoolHasRoomForZip64Placeholders(t *testing.T) {
	if got := (Limited{}).memoryFor("exiftool"); got <= MostMemory {
		t.Fatalf("exiftool gets %d bytes, which a zip64 header's placeholder size overruns", got)
	}
	if got := (Limited{}).memoryFor("pdftotext"); got != MostMemory {
		t.Fatalf("pdftotext gets %d bytes", got)
	}
	if got := (Limited{Memory: 64 << 20}).memoryFor("exiftool"); got != 64<<20 {
		t.Fatalf("an explicit cap was overridden: %d", got)
	}
}

func TestLimitedCapsEachProgramByName(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("only Linux honors a data limit")
	}

	saved := ProgramMemory
	ProgramMemory = map[string]uint64{"sh": 96 << 20}
	defer func() { ProgramMemory = saved }()

	out, err := Limited{}.Run(context.Background(), 5*time.Second, "sh", "-c", "ulimit -d")
	if err != nil {
		t.Fatal(err)
	}

	if strings.TrimSpace(string(out)) != "98304" {
		t.Fatalf("the data limit is %q", out)
	}
}

func TestLimitedReportsAMissingProgram(t *testing.T) {
	_, err := Limited{}.Run(context.Background(), 5*time.Second, "xixo-no-such-program")
	if err == nil {
		t.Fatal("a missing program ran")
	}
}
