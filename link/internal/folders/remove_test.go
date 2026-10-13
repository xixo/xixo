package folders

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func sum(body string) string {
	hashed := sha256.Sum256([]byte(body))

	return hex.EncodeToString(hashed[:])
}

func TestWriteKeepsTheModifiedTimeAsked(t *testing.T) {
	shared, _, held := writableTree(t)
	modified := time.Date(2019, 7, 4, 12, 30, 15, 123456789, time.UTC)

	written, err := held.WriteModified(shared, "photos/old.nef", strings.NewReader("raw"), 3, false, modified)
	if err != nil {
		t.Fatal(err)
	}

	if !written.ModifiedAt.Equal(modified) {
		t.Fatalf("answered %v, want %v", written.ModifiedAt, modified)
	}

	info, err := os.Stat(filepath.Join(shared, "photos", "old.nef"))
	if err != nil || !info.ModTime().Equal(modified) {
		t.Fatalf("on disk %v %v", info.ModTime(), err)
	}
}

func TestRemoveTakesOnlyTheFileWithTheBytesNamed(t *testing.T) {
	shared, _, held := writableTree(t)

	if _, err := held.Remove(shared, "a.txt", sum("not a"), 1, false); !errors.Is(err, ErrChanged) {
		t.Fatalf("other bytes gave %v", err)
	}

	if _, err := held.Remove(shared, "a.txt", sum("a"), 2, false); !errors.Is(err, ErrChanged) {
		t.Fatalf("another size gave %v", err)
	}

	if _, err := os.Stat(filepath.Join(shared, "a.txt")); err != nil {
		t.Fatalf("a file that did not match was removed: %v", err)
	}

	removed, err := held.Remove(shared, "a.txt", sum("a"), 1, false)
	if err != nil || removed.Path != "a.txt" || removed.Size != 1 {
		t.Fatalf("removed %+v %v", removed, err)
	}

	if _, err := os.Stat(filepath.Join(shared, "a.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a.txt is still there: %v", err)
	}
}

func TestRemoveRefusesWhatItMustNotTouch(t *testing.T) {
	shared, outside, held := writableTree(t)
	readOnly := filepath.Join(filepath.Dir(shared), "kept")
	os.WriteFile(filepath.Join(readOnly, "note.txt"), []byte("x"), 0o644)

	cases := []struct {
		folder, name, sum string
		want              error
	}{
		{readOnly, "note.txt", sum("x"), ErrReadOnly},
		{outside, "secret.txt", sum("secret"), ErrUnshared},
		{shared, "../outside/secret.txt", sum("secret"), ErrOutside},
		{shared, "/etc/passwd", sum("x"), ErrOutside},
		{shared, "link", sum("secret"), ErrOutside},
		{shared, "linkdir/private.txt", sum("private"), ErrOutside},
		{shared, "c/inside", sum("a"), ErrOutside},
		{shared, ".git/config", sum("secret"), ErrSkipped},
		{shared, "node_modules/x.js", sum("x"), ErrSkipped},
		{shared, "c", sum("x"), ErrNotFile},
		{shared, "a.txt", "", ErrNoHash},
		{shared, "a.txt", strings.ToUpper(sum("a")), ErrNoHash},
	}

	for _, refused := range cases {
		_, err := held.Remove(refused.folder, refused.name, refused.sum, 1, false)
		if !errors.Is(err, refused.want) {
			t.Errorf("%s in %s: got %v, want %v", refused.name, refused.folder, err, refused.want)
		}
	}

	for _, kept := range []string{
		filepath.Join(outside, "secret.txt"), filepath.Join(outside, "inner", "private.txt"),
		filepath.Join(shared, ".git", "config"), filepath.Join(readOnly, "note.txt"), filepath.Join(shared, "a.txt"),
	} {
		if _, err := os.Stat(kept); err != nil {
			t.Errorf("%s was removed: %v", kept, err)
		}
	}
}

func TestRemovePrunesTheFoldersItEmptiedAndNoMore(t *testing.T) {
	shared, _, held := writableTree(t)
	os.MkdirAll(filepath.Join(shared, "trip", "day1"), 0o755)
	os.WriteFile(filepath.Join(shared, "trip", "day1", "one.nef"), []byte("one"), 0o644)
	os.WriteFile(filepath.Join(shared, "trip", "day1", ".DS_Store"), []byte("ds"), 0o644)
	os.WriteFile(filepath.Join(shared, "trip", "keep.txt"), []byte("keep"), 0o644)

	removed, err := held.Remove(shared, "trip/day1/one.nef", sum("one"), 3, true)
	if err != nil {
		t.Fatal(err)
	}

	if !slices.Equal(removed.Pruned, []string{"trip/day1"}) {
		t.Fatalf("pruned %v", removed.Pruned)
	}

	if _, err := os.Stat(filepath.Join(shared, "trip", "keep.txt")); err != nil {
		t.Fatalf("a folder still holding a file was pruned: %v", err)
	}

	removed, err = held.Remove(shared, "trip/keep.txt", sum("keep"), 4, true)
	if err != nil || !slices.Equal(removed.Pruned, []string{"trip"}) {
		t.Fatalf("pruned %+v %v", removed, err)
	}

	if _, err := os.Stat(shared); err != nil {
		t.Fatalf("the shared folder itself was removed: %v", err)
	}

	removed, err = held.Remove(shared, "c/d/e.txt", sum("e"), 1, false)
	if err != nil || len(removed.Pruned) != 0 {
		t.Fatalf("pruned unasked %+v %v", removed, err)
	}

	if _, err := os.Stat(filepath.Join(shared, "c", "d")); err != nil {
		t.Fatalf("an emptied folder was pruned unasked: %v", err)
	}
}

func TestPruningKeepsAFolderThatHoldsANameNeverShared(t *testing.T) {
	shared, _, held := writableTree(t)
	os.MkdirAll(filepath.Join(shared, "project", "node_modules"), 0o755)
	os.WriteFile(filepath.Join(shared, "project", "index.js"), []byte("js"), 0o644)
	os.WriteFile(filepath.Join(shared, "project", "node_modules", "dep.js"), []byte("dep"), 0o644)

	removed, err := held.Remove(shared, "project/index.js", sum("js"), 2, true)
	if err != nil || len(removed.Pruned) != 0 {
		t.Fatalf("pruned %+v %v", removed, err)
	}

	if _, err := os.Stat(filepath.Join(shared, "project", "node_modules", "dep.js")); err != nil {
		t.Fatalf("a name never shared was removed: %v", err)
	}
}
