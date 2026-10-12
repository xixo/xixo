package extract

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func macReader(t *testing.T) {
	t.Helper()

	built, err := filepath.Abs("../../macos/build")
	if err != nil {
		t.Fatal(err)
	}

	t.Setenv("PATH", built+string(os.PathListSeparator)+os.Getenv("PATH"))

	if MacReader() == "" {
		t.Skip("build the mac reader with make -C macos to run these")
	}
}

func placedIn(t *testing.T, work string, files map[string]string) {
	t.Helper()

	for from, to := range files {
		raw, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}

		if err := os.WriteFile(filepath.Join(work, to), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestTheMacReaderIsFoundBesideTheAgentFirst(t *testing.T) {
	dir := t.TempDir()
	beside := filepath.Join(dir, MacReaderName)

	for _, name := range []string{beside, filepath.Join(dir, "xixo-agent")} {
		if err := os.WriteFile(name, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	held := executable
	executable = func() (string, error) { return filepath.Join(dir, "xixo-agent"), nil }
	t.Cleanup(func() { executable = held })

	real, _ := filepath.EvalSymlinks(beside)
	if found := MacReader(); found != real {
		t.Fatalf("found %q", found)
	}
}

func TestTheMacReaderReadsUnderTheSandbox(t *testing.T) {
	macReader(t)

	run, work := sandboxed(t)
	real, _ := filepath.EvalSymlinks(work)

	placedIn(t, real, map[string]string{
		"documents/testdata/report.pdf":      "source.pdf",
		"documents/testdata/scanned.pdf":     "scanned.pdf",
		"documents/testdata/ocr-receipt.png": "receipt.png",
		"documents/testdata/photo.heic":      "photo.heic",
		"documents/testdata/animated.gif":    "animated.gif",
		"rich/testdata/clip.mp4":             "clip.mp4",
	})

	ctx := context.Background()
	in := func(name string) string { return filepath.Join(real, name) }

	var pdf struct {
		Info  map[string]any `json:"info"`
		Pages []string       `json:"pages"`
	}
	if err := AskMac(ctx, run, time.Minute, &pdf, "pdf", in("source.pdf")); err != nil {
		t.Fatal(err)
	}
	if len(pdf.Pages) == 0 || !strings.Contains(strings.Join(pdf.Pages, "\f"), "PDFREPORT-7715") {
		t.Fatalf("the pdf read %+v", pdf)
	}

	var ocr struct {
		Pages []struct {
			Text string `json:"text"`
		} `json:"pages"`
	}
	if err := AskMac(ctx, run, time.Minute, &ocr, "ocr", in("receipt.png")); err != nil {
		t.Fatal(err)
	}
	if len(ocr.Pages) != 1 || !strings.Contains(ocr.Pages[0].Text, "OCRRECEIPT-9042") {
		t.Fatalf("vision read %+v", ocr)
	}

	if err := AskMac(ctx, run, time.Minute, &ocr, "ocr", in("scanned.pdf"), "--kind", "pdf", "--pages", "2"); err != nil {
		t.Fatal(err)
	}
	if len(ocr.Pages) == 0 || strings.TrimSpace(ocr.Pages[0].Text) == "" {
		t.Fatalf("vision read nothing in the scanned pdf: %+v", ocr)
	}

	var image map[string]any
	if err := AskMac(ctx, run, time.Minute, &image, "image", in("photo.heic")); err != nil {
		t.Fatal(err)
	}
	if image["width"] == nil || image["deviation"] == nil {
		t.Fatalf("the heic read %+v", image)
	}

	var made map[string]any
	for _, each := range [][]string{
		{"thumbnail", in("photo.heic"), "--kind", "image", "--out", in("heic.jpg"), "--width", "320"},
		{"thumbnail", in("source.pdf"), "--kind", "pdf", "--out", in("page.jpg"), "--width", "320"},
		{"thumbnail", in("clip.mp4"), "--kind", "video", "--out", in("poster.jpg"), "--width", "320"},
		{"frames", in("animated.gif"), "--index", "0,2", "--out", real, "--width", "200"},
		{"media", in("clip.mp4")},
		{"metadata", in("photo.heic"), "--kind", "image"},
	} {
		if err := AskMac(ctx, run, time.Minute, &made, each[0], each[1], each[2:]...); err != nil {
			t.Fatalf("%s: %v", each[0], err)
		}
	}

	for _, name := range []string{"heic.jpg", "page.jpg", "poster.jpg", "frame-0.jpg", "frame-2.jpg"} {
		if info, err := os.Stat(in(name)); err != nil || info.Size() == 0 {
			t.Fatalf("%s was not made: %v", name, err)
		}
	}
}

func TestTheMacReaderWritesNothingOutsideTheWorkFolder(t *testing.T) {
	macReader(t)

	run, work := sandboxed(t)
	real, _ := filepath.EvalSymlinks(work)
	placedIn(t, real, map[string]string{"documents/testdata/photo.jpg": "photo.jpg"})

	outside := filepath.Join(t.TempDir(), "escaped.jpg")

	var made map[string]any
	err := AskMac(context.Background(), run, time.Minute, &made, "thumbnail", filepath.Join(real, "photo.jpg"),
		"--kind", "image", "--out", outside, "--width", "64")
	if err == nil {
		t.Fatal("the mac reader wrote outside the work folder")
	}

	if _, err := os.Stat(outside); err == nil {
		t.Fatal("a file outside the work folder exists")
	}
}

func TestTextutilReadsUnderTheSandbox(t *testing.T) {
	if !Present("textutil") {
		t.Skip("no textutil")
	}

	run, work := sandboxed(t)
	real, _ := filepath.EvalSymlinks(work)
	source := filepath.Join(real, "note.rtf")

	if err := os.WriteFile(source, []byte(`{\rtf1\ansi{\info{\author Bea Okonkwo}}Needle: RTF-3318\par}`), 0o600); err != nil {
		t.Fatal(err)
	}

	said, err := run.Run(context.Background(), time.Minute, "textutil", "-convert", "txt", "-encoding", "UTF-8", "-stdout", source)
	if err != nil || !strings.Contains(string(said), "RTF-3318") {
		t.Fatalf("textutil read %q: %v", said, err)
	}

	said, err = run.Run(context.Background(), time.Minute, "textutil", "-info", "-format", "rtf", source)
	if err != nil {
		t.Fatal(err)
	}

	if found := TextutilInfo(string(said)); len(found) == 0 || found[0].Value != "Bea Okonkwo" {
		t.Fatalf("textutil said %q, read %+v", said, found)
	}
}
