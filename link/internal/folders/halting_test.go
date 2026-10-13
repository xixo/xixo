package folders

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type trickle struct{}

func (trickle) Read(p []byte) (int, error) {
	time.Sleep(time.Millisecond)

	return copy(p, "x"), nil
}

type lastly struct {
	io.Reader
	then func()
}

func (l *lastly) Read(p []byte) (int, error) {
	count, err := l.Reader.Read(p)
	if errors.Is(err, io.EOF) {
		l.then()
	}

	return count, err
}

func leftIn(t *testing.T, dir string) []string {
	t.Helper()

	entries, err := os.ReadDir(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}

	held := []string{}
	for _, entry := range entries {
		held = append(held, entry.Name())
	}

	return held
}

func TestAHaltingReaderStopsWhenItsContextEnds(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()

	started := time.Now()

	if _, err := io.Copy(io.Discard, Halting(ctx, trickle{})); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the copy ended with %v", err)
	}

	if took := time.Since(started); took > time.Second {
		t.Fatalf("the copy went on for %v after its context ended", took)
	}
}

func TestAWriteCutShortLeavesNoFile(t *testing.T) {
	shared, _, held := writableTree(t)

	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()

	_, err := held.Write(ctx, shared, "movies/long.mkv", trickle{}, 10<<20, false)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the write ended with %v", err)
	}

	if left := leftIn(t, filepath.Join(shared, "movies")); len(left) != 0 {
		t.Fatalf("a write cut short left %v", left)
	}
}

func TestAWriteWhoseContextEndsAfterItsBytesArrivePlacesNothing(t *testing.T) {
	shared, _, held := writableTree(t)

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	body := &lastly{Reader: strings.NewReader("hello"), then: cancel}

	if _, err := held.Write(ctx, shared, "movies/short.mkv", body, 5, false); !errors.Is(err, context.Canceled) {
		t.Fatalf("the write ended with %v", err)
	}

	if left := leftIn(t, filepath.Join(shared, "movies")); len(left) != 0 {
		t.Fatalf("a write stopped before placing left %v", left)
	}
}

func TestAReplacementCutShortKeepsTheFileItWouldReplace(t *testing.T) {
	shared, _, held := writableTree(t)

	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()

	if _, err := held.Write(ctx, shared, "a.txt", trickle{}, 10<<20, true); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the write ended with %v", err)
	}

	if body, _ := os.ReadFile(filepath.Join(shared, "a.txt")); string(body) != "a" {
		t.Fatalf("a.txt became %q", body)
	}

	for _, name := range leftIn(t, shared) {
		if strings.HasPrefix(name, ".xixo-") {
			t.Fatalf("a replacement cut short left %s", name)
		}
	}
}

func TestARemovalWhoseContextEndedKeepsTheOriginal(t *testing.T) {
	shared, _, held := writableTree(t)

	ctx, cancel := context.WithCancel(t.Context())
	cancel()

	if _, err := held.Remove(ctx, shared, "a.txt", sum("a"), 1, false); !errors.Is(err, context.Canceled) {
		t.Fatalf("the removal ended with %v", err)
	}

	if body, _ := os.ReadFile(filepath.Join(shared, "a.txt")); string(body) != "a" {
		t.Fatalf("a.txt became %q", body)
	}
}

func TestAListingStopsWhenItsContextEnds(t *testing.T) {
	shared, _, held := writableTree(t)

	ctx, cancel := context.WithCancel(t.Context())
	cancel()

	if _, err := held.List(ctx, Query{Folder: shared}); !errors.Is(err, context.Canceled) {
		t.Fatalf("the listing ended with %v", err)
	}
}
