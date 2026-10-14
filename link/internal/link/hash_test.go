package link

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
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
	os.WriteFile(filepath.Join(dir, "report.doc"), body, 0o600)

	held := &Link{Folders: folders.New(folders.ReadOnly(dir)), Digests: &digests.Cache{}}

	opened, err := held.Folders.Open(dir, "report.doc")
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()

	_, digest, err := held.copySource(context.Background(), opened, t.TempDir(), ".doc")
	if err != nil {
		t.Fatal(err)
	}

	hashed, err := held.hashed(context.Background(), Read{Folder: dir, Path: "report.doc"})
	if err != nil {
		t.Fatal(err)
	}

	if hashed.SHA256 != digest.SHA256 || held.Digests.Hashed() != 0 {
		t.Fatalf("hashed %+v after the extraction's %+v, reading %d bytes", hashed, digest, held.Digests.Hashed())
	}
}

func TestAnExtractionWhereTheFileLiesHashesItOnceAndCopiesNothing(t *testing.T) {
	dir := t.TempDir()
	body := make([]byte, 2<<20)
	os.WriteFile(filepath.Join(dir, "film.mkv"), body, 0o600)

	held := &Link{Folders: folders.New(folders.ReadOnly(dir)), Digests: &digests.Cache{}}
	work := t.TempDir()

	source, err := held.source(context.Background(), Extraction{Source: Source{Folder: dir, Path: "film.mkv"}, MIME: "video/x-matroska"}, work)
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()

	if want := sha256.Sum256(body); source.digest.SHA256 != hex.EncodeToString(want[:]) || source.digest.Size != int64(len(body)) {
		t.Fatalf("the extraction named %+v", source.digest)
	}

	info, err := os.Lstat(source.path)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the work folder holds a copy, not a link: %v", err)
	}

	read, err := os.ReadFile(source.path)
	if err != nil || len(read) != len(body) {
		t.Fatalf("the source read %d bytes: %v", len(read), err)
	}

	if err := source.settled(); err != nil {
		t.Fatalf("an unchanged file did not settle: %v", err)
	}

	if _, err := held.hashed(context.Background(), Read{Folder: dir, Path: "film.mkv"}); err != nil || held.Digests.Hashed() != int64(len(body)) {
		t.Fatalf("the film was read %d bytes in all: %v", held.Digests.Hashed(), err)
	}
}

func TestAFileThatChangesDuringAnExtractionSendsNothing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "film.mkv")
	os.WriteFile(path, []byte("first cut"), 0o600)

	held := &Link{Folders: folders.New(folders.ReadOnly(dir))}

	source, err := held.source(context.Background(), Extraction{Source: Source{Folder: dir, Path: "film.mkv"}, MIME: "video/x-matroska"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()

	time.Sleep(20 * time.Millisecond)

	if err := os.WriteFile(path, []byte("final cut"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := source.settled(); !errors.Is(err, ErrShifted) {
		t.Fatalf("a file written during the extraction settled with %v", err)
	}
}

func TestAFileReplacedDuringAnExtractionSendsNothing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "film.mkv")
	os.WriteFile(path, []byte("first cut"), 0o600)

	held := &Link{Folders: folders.New(folders.ReadOnly(dir))}

	source, err := held.source(context.Background(), Extraction{Source: Source{Folder: dir, Path: "film.mkv"}, MIME: "video/x-matroska"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()

	os.Rename(path, path+".old")
	os.WriteFile(path, []byte("other film"), 0o600)

	err = source.settled()

	switch {
	case len(source.from.Reads) > 0 && !errors.Is(err, ErrShifted):
		t.Fatalf("a file replaced at its path settled with %v", err)
	case len(source.from.Reads) == 0 && err != nil:
		t.Fatalf("the file the programs read did not change, yet it settled with %v", err)
	}
}
