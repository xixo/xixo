package verify

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/theupdateframework/go-tuf/v2/metadata"
)

func TestTheMirrorHoldsOnlyFilesFromSigstoresRepository(t *testing.T) {
	mirror := t.TempDir()

	for _, address := range []string{
		"https://example.com/12.root.json",
		Repository + "/",
		Repository + "/../../etc/passwd",
		Repository + "/targets/%2e%2e/x",
	} {
		if target, err := mirrored(mirror, address); err == nil {
			t.Fatalf("%s mirrored to %s", address, target)
		}
	}

	target, err := mirrored(mirror, Repository+"/targets/abc.trusted_root.json")
	if err != nil || target != filepath.Join(mirror, "targets", "abc.trusted_root.json") {
		t.Fatalf("target %q err %v", target, err)
	}
}

func TestAReplayAnswersFromTheMirrorAndTreatsAMissingFileAsNotFound(t *testing.T) {
	mirror := t.TempDir()
	os.WriteFile(filepath.Join(mirror, "timestamp.json"), []byte("held"), 0o644)
	replay := &replaying{mirror: mirror}

	held, err := replay.DownloadFile(Repository+"/timestamp.json", 100, 0)
	if err != nil || string(held) != "held" {
		t.Fatalf("held %q err %v", held, err)
	}

	if _, err := replay.DownloadFile(Repository+"/timestamp.json", 2, 0); err == nil {
		t.Fatal("a file larger than asked was read")
	}

	_, err = replay.DownloadFile(Repository+"/13.root.json", 100, 0)
	var missing *metadata.ErrDownloadHTTP
	if !errors.As(err, &missing) || missing.StatusCode != 404 {
		t.Fatalf("err %v", err)
	}
}

func TestTheGateTrustsWhatTheUpdaterMirrored(t *testing.T) {
	if testing.Short() || os.Getenv("XIXO_ONLINE") == "" {
		t.Skip("reaches sigstore's TUF repository; set XIXO_ONLINE=1")
	}

	mirror := t.TempDir()
	if _, err := Live(mirror, t.TempDir()); err != nil {
		t.Fatal(err)
	}

	trusted, err := Mirrored(mirror, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	if _, err := (&Checker{Trusted: trusted}).Check(bundled(t), built, xixo); err != nil {
		t.Fatal(err)
	}

	os.WriteFile(filepath.Join(mirror, "timestamp.json"), []byte(`{"signed":{}}`), 0o644)
	if _, err := Mirrored(mirror, t.TempDir()); err == nil {
		t.Fatal("a forged timestamp was trusted")
	}
}
