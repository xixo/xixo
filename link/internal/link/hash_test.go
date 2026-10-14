package link

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/digests"
	"github.com/xixo/xixo/link/internal/folders"
)

func TestALargeFileIsHashedOnceUntilItChanges(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "film.mkv")
	body := make([]byte, 2<<20)
	os.WriteFile(path, body, 0o600)

	held := &Link{Folders: folders.New(folders.ReadOnly(dir)), Digests: &digests.Cache{}}
	asked := Read{Folder: dir, Path: "film.mkv"}

	for range 3 {
		hashed, err := held.hashed(context.Background(), asked)
		if err != nil {
			t.Fatal(err)
		}

		if want := sha256.Sum256(body); hashed.SHA256 != hex.EncodeToString(want[:]) || hashed.Size != int64(len(body)) || hashed.File == "" {
			t.Fatalf("hashed %+v", hashed)
		}
	}

	if read := held.Digests.Hashed(); read != int64(len(body)) {
		t.Fatalf("three asks read %d bytes", read)
	}

	info, _ := os.Stat(path)
	time.Sleep(20 * time.Millisecond)
	body[0] = 1
	os.WriteFile(path, body, 0o600)
	os.Chtimes(path, info.ModTime(), info.ModTime())

	hashed, err := held.hashed(context.Background(), asked)
	if err != nil {
		t.Fatal(err)
	}

	if want := sha256.Sum256(body); hashed.SHA256 != hex.EncodeToString(want[:]) {
		t.Fatal("a file rewritten with the same size and time kept its old digest")
	}

	if read := held.Digests.Hashed(); read != 2*int64(len(body)) {
		t.Fatalf("the rewrite was not read again: %d bytes", read)
	}
}

func TestAnExtractionRemembersTheDigestOfTheFileItCopied(t *testing.T) {
	dir := t.TempDir()
	body := make([]byte, 2<<20)
	os.WriteFile(filepath.Join(dir, "film.mkv"), body, 0o600)

	held := &Link{Folders: folders.New(folders.ReadOnly(dir)), Digests: &digests.Cache{}}
	work := t.TempDir()

	_, digest, err := held.source(context.Background(), Extraction{Source: Source{Folder: dir, Path: "film.mkv"}}, work)
	if err != nil {
		t.Fatal(err)
	}

	hashed, err := held.hashed(context.Background(), Read{Folder: dir, Path: "film.mkv"})
	if err != nil {
		t.Fatal(err)
	}

	if hashed.SHA256 != digest.SHA256 || held.Digests.Hashed() != 0 {
		t.Fatalf("hashed %+v after the extraction's %+v, reading %d bytes", hashed, digest, held.Digests.Hashed())
	}
}
