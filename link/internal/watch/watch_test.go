package watch

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func watching(t *testing.T, w *Watcher) (string, <-chan Change) {
	t.Helper()

	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	os.MkdirAll(filepath.Join(root, "old", "deep"), 0o755)
	os.MkdirAll(filepath.Join(root, ".git"), 0o755)

	w.Roots = map[string]string{"/shared": root}
	if w.Settle == 0 {
		w.Settle = 100 * time.Millisecond
	}

	ctx, cancel := context.WithCancel(context.Background())
	changes := make(chan Change, 16)
	done := make(chan struct{})

	go func() {
		defer close(done)
		w.Run(ctx, func(change Change) { changes <- change })
	}()

	t.Cleanup(func() {
		cancel()
		<-done
	})

	time.Sleep(200 * time.Millisecond)

	return root, changes
}

func next(t *testing.T, changes <-chan Change) Change {
	t.Helper()

	select {
	case change := <-changes:
		return change
	case <-time.After(5 * time.Second):
		t.Fatal("no change arrived")
	}

	return Change{}
}

func TestAWrittenFileIsToldByItsPathWithinTheFolder(t *testing.T) {
	root, changes := watching(t, &Watcher{})

	os.WriteFile(filepath.Join(root, "old", "deep", "plan.txt"), []byte("plan"), 0o644)

	change := next(t, changes)
	if change.Folder != "/shared" || change.Overflow || !slices.Contains(change.Paths, "old/deep/plan.txt") {
		t.Fatalf("told %+v", change)
	}
}

func TestANewFolderIsWatchedAndToldAndWhatLandsInItToo(t *testing.T) {
	root, changes := watching(t, &Watcher{})

	os.Mkdir(filepath.Join(root, "new"), 0o755)

	if change := next(t, changes); !slices.Contains(change.Paths, "new") {
		t.Fatalf("told %+v", change)
	}

	os.WriteFile(filepath.Join(root, "new", "song.mp3"), []byte("ID3"), 0o644)

	if change := next(t, changes); !slices.Contains(change.Paths, "new/song.mp3") {
		t.Fatalf("told %+v", change)
	}
}

func TestARemovedFileIsTold(t *testing.T) {
	root, changes := watching(t, &Watcher{})
	gone := filepath.Join(root, "old", "gone.txt")
	os.WriteFile(gone, []byte("x"), 0o644)
	next(t, changes)

	os.Remove(gone)

	if change := next(t, changes); !slices.Contains(change.Paths, "old/gone.txt") {
		t.Fatalf("told %+v", change)
	}
}

func TestNamesNeverSharedAreNeverTold(t *testing.T) {
	root, changes := watching(t, &Watcher{Skip: func(name string) bool { return name == ".git" }})

	os.WriteFile(filepath.Join(root, ".git", "HEAD"), []byte("ref"), 0o644)
	os.WriteFile(filepath.Join(root, "kept.txt"), []byte("kept"), 0o644)

	change := next(t, changes)
	if !slices.Equal(change.Paths, []string{"kept.txt"}) {
		t.Fatalf("told %+v", change)
	}
}

func TestMoreChangesThanABatchHoldsAreToldAsAnOverflow(t *testing.T) {
	root, changes := watching(t, &Watcher{Batch: 3, Settle: 300 * time.Millisecond})

	for _, name := range []string{"a", "b", "c", "d", "e"} {
		os.WriteFile(filepath.Join(root, name), []byte(name), 0o644)
	}

	change := next(t, changes)
	if !change.Overflow || len(change.Paths) != 0 {
		t.Fatalf("told %+v", change)
	}
}

func TestWatchingStopsAtTheMostFoldersAndSaysSo(t *testing.T) {
	w := &Watcher{Most: 1}
	watching(t, w)

	warnings := w.Warnings()
	if len(warnings) != 1 || !slices.ContainsFunc(warnings, func(said string) bool { return said != "" }) {
		t.Fatalf("warned %q", warnings)
	}
}
