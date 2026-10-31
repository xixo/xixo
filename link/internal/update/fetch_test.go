package update

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/release"
)

func fetching(t *testing.T, fresh []byte) (*Fetcher, map[string][]byte, Target) {
	t.Helper()
	files := map[string][]byte{"xixo-link-linux-amd64": fresh, Service: []byte(template), UpdateTimer: []byte("[Timer]")}
	target, _ := listed(t, files, "0.3.0", 20,
		entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh),
		entry(Service, "", "", release.RoleUnit, []byte(template)),
		entry(UpdateTimer, "", "", release.RoleUnit, []byte("[Timer]")))
	target.SHA256 = sum(fresh)
	server, _ := served(t, files)
	requests := t.TempDir()
	cache := t.TempDir()
	Write(filepath.Join(requests, RequestFile), Request{Target: target, From: "0.2.0", RequestedAt: time.Now().UTC()}, 0o644)

	return &Fetcher{
		Xixo: server.URL, Requests: requests, Cache: cache, OS: "linux", Arch: "amd64", Client: server.Client(),
		Vouch: &Vouch{Unsigned: true, Xixo: server.URL, Client: server.Client(), Floor: filepath.Join(t.TempDir(), FloorFile)},
	}, files, target
}

func TestTheFetcherStagesEveryFileOfTheReleaseForRoot(t *testing.T) {
	fresh := script("echo 0.3.0")
	fetcher, _, target := fetching(t, fresh)
	stale := filepath.Join(fetcher.Cache, StagedDir, "0000000000000000")
	os.MkdirAll(stale, 0o755)

	if err := fetcher.Fetch(context.Background()); err != nil {
		t.Fatal(err)
	}

	staged, id := Staged(filepath.Join(fetcher.Cache, StagedDir))
	if staged == "" || id != target.Release[:16] {
		t.Fatalf("staged %q as %q", staged, id)
	}

	for name, want := range map[string]os.FileMode{"xixo-link-linux-amd64": 0o755, Service: 0o644, UpdateTimer: 0o644, release.File: 0o644, RequestKept: 0o644} {
		info, err := os.Stat(filepath.Join(staged, name))
		if err != nil || info.Mode().Perm() != want {
			t.Fatalf("%s: %v %v", name, info, err)
		}
	}

	if sha, _ := Digest(filepath.Join(staged, "xixo-link-linux-amd64")); sha != sum(fresh) {
		t.Fatal("the staged binary is not the one served")
	}

	if _, err := os.Stat(stale); err == nil {
		t.Fatal("an older staged release stayed")
	}

	told := Result{}
	if err := Read(filepath.Join(fetcher.Cache, FetchFile), &told); err != nil || !told.OK || told.SHA256 != sum(fresh) {
		t.Fatalf("fetch result %+v: %v", told, err)
	}

	if err := fetcher.Fetch(context.Background()); err != nil {
		t.Fatalf("fetching a release already staged: %v", err)
	}
}

func TestTheFetcherStagesNothingWhenAFileDoesNotMatch(t *testing.T) {
	fetcher, files, _ := fetching(t, script("echo 0.3.0"))
	files[Service] = []byte("[Service]\ntampered\n")

	if err := fetcher.Fetch(context.Background()); !errors.Is(err, ErrMismatch) {
		t.Fatalf("fetch: %v", err)
	}

	if staged, _ := Staged(filepath.Join(fetcher.Cache, StagedDir)); staged != "" {
		t.Fatalf("a release with a tampered unit was staged at %s", staged)
	}

	entries, _ := os.ReadDir(filepath.Join(fetcher.Cache, StagedDir))
	if len(entries) != 0 {
		t.Fatalf("staging left %v behind", entries)
	}

	told := Result{}
	if Read(filepath.Join(fetcher.Cache, FetchFile), &told); told.OK || told.Error == "" {
		t.Fatalf("fetch result %+v", told)
	}
}

func TestTheFetcherDoesNothingWithoutARequest(t *testing.T) {
	fetcher, _, _ := fetching(t, script("echo 0.3.0"))
	os.Remove(filepath.Join(fetcher.Requests, RequestFile))

	if err := fetcher.Fetch(context.Background()); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(fetcher.Cache, FetchFile)); err == nil {
		t.Fatal("a fetch with no request left a result")
	}
}
