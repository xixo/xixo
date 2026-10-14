package extract

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func sharedFile(t *testing.T, body string) (*os.File, string, string) {
	t.Helper()

	shared := t.TempDir()
	path := filepath.Join(shared, "film.txt")

	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { file.Close() })

	return file, path, t.TempDir()
}

func TestAProgramAndGoCodeReadASharedFileWhereItLies(t *testing.T) {
	file, _, work := sharedFile(t, "the whole film")

	source, err := InPlace(file, work, ".txt")
	if err != nil {
		t.Skip(err)
	}

	if filepath.Dir(source.Path) != work || filepath.Ext(source.Path) != ".txt" {
		t.Fatalf("the source is named %s", source.Path)
	}

	run := Reading(Within(Limited{}, work, 1<<30), source)

	for range 2 {
		out, err := run.Run(context.Background(), 10*time.Second, "cat", source.Path)
		if err != nil || string(out) != "the whole film" {
			t.Fatalf("the program read %q: %v", out, err)
		}
	}

	read, err := os.ReadFile(source.Path)
	if err != nil || string(read) != "the whole film" {
		t.Fatalf("Go code read %q: %v", read, err)
	}

	info, err := os.Lstat(source.Path)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the source in the work folder is not a link: %v", err)
	}
}

func TestOnLinuxAFileReplacedMidReadStillReadsTheFileThatWasOpened(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("only Linux hands the open file itself to each program")
	}

	file, path, work := sharedFile(t, "first cut")

	source, err := InPlace(file, work, ".txt")
	if err != nil {
		t.Fatal(err)
	}

	if err := os.Rename(path, path+".old"); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(path, []byte("swapped"), 0o644); err != nil {
		t.Fatal(err)
	}

	out, err := Reading(Within(Limited{}, work, 1<<30), source).Run(context.Background(), 10*time.Second, "cat", source.Path)
	if err != nil || string(out) != "first cut" {
		t.Fatalf("the program read %q: %v", out, err)
	}

	if source.Reads != nil || source.Inherit == nil {
		t.Fatalf("a Linux source names paths to read: %+v", source)
	}
}

func TestTheSandboxProfileNamesOnlyTheSharedFile(t *testing.T) {
	held, err := Profile("/work/extract-1", "ffprobe", "/Volumes/Media/Movies/A \"film\".mkv")
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(held, `(allow file-read* (literal "/Volumes/Media/Movies/A \"film\".mkv"))`) {
		t.Fatalf("the profile does not name the file:\n%s", held)
	}

	if strings.Contains(held, `(subpath "/Volumes/Media`) {
		t.Fatalf("the profile opens the whole folder:\n%s", held)
	}

	if _, err := Profile("/work/extract-1", "ffprobe", "Movies/film.mkv"); err == nil {
		t.Fatal("a relative read was allowed")
	}
}
