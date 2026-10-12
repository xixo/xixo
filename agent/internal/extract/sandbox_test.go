package extract

import (
	"errors"
	"strings"
	"testing"
)

func TestProfileDeniesByDefaultAndWritesOnlyTheWorkFolder(t *testing.T) {
	held, err := Profile("/Users/someone/Library/Caches/xixo-agent/work/extract-1", "pdftotext")
	if err != nil {
		t.Fatal(err)
	}

	for _, want := range []string{
		"(deny default)",
		`(allow file-write* (subpath "/Users/someone/Library/Caches/xixo-agent/work/extract-1"))`,
		`(literal "/Users/someone/Library")`,
		`(deny file-read* (subpath "/opt/homebrew/var")`,
	} {
		if !strings.Contains(held, want) {
			t.Errorf("the profile lacks %s:\n%s", want, held)
		}
	}

	for _, unwanted := range []string{"network", "mach-lookup", "LibreOffice", `(subpath "/Users/someone/Library")`} {
		if strings.Contains(held, unwanted) {
			t.Errorf("the profile holds %s:\n%s", unwanted, held)
		}
	}
}

func TestProfileOpensLibreOfficeOnlyForSoffice(t *testing.T) {
	held, err := Profile("/work/extract-1", "/opt/homebrew/bin/soffice")
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(held, `(subpath "/Applications/LibreOffice.app")`) || !strings.Contains(held, "OSL_PIPE_") {
		t.Fatalf("soffice cannot start:\n%s", held)
	}

	if strings.Contains(held, "(remote") {
		t.Fatalf("soffice reaches the network:\n%s", held)
	}
}

func TestProfileQuotesPaths(t *testing.T) {
	held, err := Profile(`/work/a "b" \c`, "x")
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(held, `(subpath "/work/a \"b\" \\c")`) {
		t.Fatalf("the path was not quoted:\n%s", held)
	}
}

func TestProfileNeedsAnAbsoluteWorkFolder(t *testing.T) {
	if _, err := Profile("", "x"); !errors.Is(err, ErrNoWork) {
		t.Fatalf("got %v", err)
	}

	if _, err := Profile("work", "x"); !errors.Is(err, ErrNoWork) {
		t.Fatalf("got %v", err)
	}
}

func TestARefusedRunnerRunsNothingAndOffersNoProgramExtractors(t *testing.T) {
	run := Limited{Refused: ErrUnconfined}

	if _, err := run.Run(t.Context(), 0, "echo", "hi"); !errors.Is(err, ErrUnconfined) {
		t.Fatalf("got %v", err)
	}

	if _, err := Within(run, t.TempDir(), 1<<20).Run(t.Context(), 0, "echo", "hi"); !errors.Is(err, ErrUnconfined) {
		t.Fatalf("within dropped the refusal: %v", err)
	}
}
