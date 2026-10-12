package plain

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestAZip64ArchiveListsItsFirstEntries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "many.zip")
	opened, _ := os.Create(path)
	writer := zip.NewWriter(opened)

	for i := range 70_000 {
		if _, err := writer.CreateHeader(&zip.FileHeader{Name: fmt.Sprintf("f%05d", i), Method: zip.Store}); err != nil {
			t.Fatal(err)
		}
	}

	writer.Close()
	opened.Close()

	listed, err := entries(context.Background(), path, "zip")
	if err != nil {
		t.Fatal(err)
	}

	if len(listed) != MostListed || listed[0] != "f00000" || listed[MostListed-1] != fmt.Sprintf("f%05d", MostListed-1) {
		t.Fatalf("listed %d: %v", len(listed), listed[:3])
	}
}

func TestAZipWithPrefixedBytesStillLists(t *testing.T) {
	held := &bytes.Buffer{}
	writer := zip.NewWriter(held)
	writer.Create("inside.txt")
	writer.Close()

	path := filepath.Join(t.TempDir(), "prefixed.zip")
	os.WriteFile(path, append([]byte("#!/bin/sh\nexit 0\n"), held.Bytes()...), 0o644)

	listed, err := entries(context.Background(), path, "zip")
	if err != nil || len(listed) != 1 || listed[0] != "inside.txt" {
		t.Fatalf("listed %v %v", listed, err)
	}
}

func TestATarListingStopsWithItsContext(t *testing.T) {
	held := &bytes.Buffer{}
	zipped := gzip.NewWriter(held)
	writer := tar.NewWriter(zipped)
	writer.WriteHeader(&tar.Header{Name: "a.txt", Size: 1, Mode: 0o644})
	writer.Write([]byte("a"))
	writer.Close()
	zipped.Close()

	path := filepath.Join(t.TempDir(), "a.tar.gz")
	os.WriteFile(path, held.Bytes(), 0o644)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := entries(ctx, path, "gzip"); !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled listing gave %v", err)
	}

	listed, err := entries(context.Background(), path, "gzip")
	if err != nil || len(listed) != 1 {
		t.Fatalf("listed %v %v", listed, err)
	}
}

func TestATarListingStopsAtWhatItInflates(t *testing.T) {
	reader := &bounded{ctx: context.Background(), from: bytes.NewReader(make([]byte, 100)), left: 10}
	buffer := make([]byte, 64)

	count, _ := reader.Read(buffer)
	if count != 10 {
		t.Fatalf("read %d", count)
	}

	if _, err := reader.Read(buffer); !errors.Is(err, errInflated) {
		t.Fatalf("read past the bound with %v", err)
	}
}
