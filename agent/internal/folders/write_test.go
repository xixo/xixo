package folders

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writableTree(t *testing.T) (string, string, *Folders) {
	t.Helper()

	shared, outside := tree(t)
	readOnly := filepath.Join(filepath.Dir(shared), "kept")
	if err := os.MkdirAll(readOnly, 0o755); err != nil {
		t.Fatal(err)
	}

	return shared, outside, New([]Shared{{Path: shared, Writable: true}, {Path: readOnly}})
}

func TestWriteMakesFoldersAndPlacesTheFile(t *testing.T) {
	shared, _, held := writableTree(t)

	written, err := held.Write(shared, "uploads/2026/note.txt", strings.NewReader("hello"), 5, false)
	if err != nil {
		t.Fatal(err)
	}

	if written.Path != "uploads/2026/note.txt" || written.Size != 5 {
		t.Fatalf("written %+v", written)
	}

	body, err := os.ReadFile(filepath.Join(shared, "uploads", "2026", "note.txt"))
	if err != nil || string(body) != "hello" {
		t.Fatalf("on disk %q %v", body, err)
	}

	left, _ := filepath.Glob(filepath.Join(shared, "uploads", "2026", ".xixo-*"))
	if len(left) != 0 {
		t.Fatalf("temporary files left behind: %v", left)
	}
}

func TestWriteKeepsAnExistingFileUnlessAskedToReplaceIt(t *testing.T) {
	shared, _, held := writableTree(t)

	if _, err := held.Write(shared, "a.txt", strings.NewReader("new"), 3, false); !errors.Is(err, ErrExists) {
		t.Fatalf("overwrote without replace: %v", err)
	}

	if body, _ := os.ReadFile(filepath.Join(shared, "a.txt")); string(body) != "a" {
		t.Fatalf("a.txt became %q", body)
	}

	if _, err := held.Write(shared, "a.txt", strings.NewReader("new"), 3, true); err != nil {
		t.Fatal(err)
	}

	if body, _ := os.ReadFile(filepath.Join(shared, "a.txt")); string(body) != "new" {
		t.Fatalf("a.txt became %q", body)
	}
}

func TestWriteRefusesWhatItMustNotTouch(t *testing.T) {
	shared, outside, held := writableTree(t)
	readOnly := filepath.Join(filepath.Dir(shared), "kept")

	cases := []struct {
		folder, name string
		want         error
	}{
		{readOnly, "note.txt", ErrReadOnly},
		{outside, "note.txt", ErrUnshared},
		{shared, "../outside/note.txt", ErrOutside},
		{shared, "/etc/passwd", ErrOutside},
		{shared, "link", ErrOutside},
		{shared, "linkdir/note.txt", ErrOutside},
		{shared, "c/inside", ErrOutside},
		{shared, ".git/hooks/post-commit", ErrSkipped},
		{shared, "node_modules/x.js", ErrSkipped},
		{shared, "notes/.DS_Store", ErrSkipped},
		{shared, ".xixo-abc.part", ErrSkipped},
		{shared, "a.txt/inner.txt", ErrOutside},
		{shared, "c", ErrNotFile},
	}

	for _, refused := range cases {
		_, err := held.Write(refused.folder, refused.name, strings.NewReader("x"), 1, true)
		if !errors.Is(err, refused.want) {
			t.Errorf("%s in %s: got %v, want %v", refused.name, refused.folder, err, refused.want)
		}
	}

	if _, err := os.Stat(filepath.Join(outside, "inner", "note.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a write followed a link out of the folder")
	}

	if body, _ := os.ReadFile(filepath.Join(outside, "secret.txt")); string(body) != "secret" {
		t.Fatalf("a write through a link changed %q", body)
	}
}

func TestWriteRefusesBytesThatDoNotMatchTheSize(t *testing.T) {
	shared, _, held := writableTree(t)

	for _, size := range []int64{3, 7} {
		if _, err := held.Write(shared, "sized.txt", strings.NewReader("hello"), size, false); !errors.Is(err, ErrShort) {
			t.Errorf("size %d: %v", size, err)
		}
	}

	if _, err := os.Stat(filepath.Join(shared, "sized.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a short write left a file behind")
	}

	left, _ := filepath.Glob(filepath.Join(shared, ".xixo-*"))
	if len(left) != 0 {
		t.Fatalf("temporary files left behind: %v", left)
	}
}

func TestOnlyWritableFoldersAreNamedWritable(t *testing.T) {
	shared, _, held := writableTree(t)

	if got := held.Writable(); len(got) != 1 || got[0] != shared {
		t.Fatalf("writable %v", got)
	}

	if len(held.Names()) != 2 {
		t.Fatalf("names %v", held.Names())
	}
}
