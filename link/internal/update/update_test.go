package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func script(body string) []byte {
	return []byte("#!/bin/sh\n" + body + "\n")
}

func sum(body []byte) string {
	hashed := sha256.Sum256(body)

	return hex.EncodeToString(hashed[:])
}

func served(t *testing.T, files map[string][]byte) (*httptest.Server, *atomic.Int32) {
	t.Helper()

	asked := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		asked.Add(1)

		body, ok := files[strings.TrimPrefix(request.URL.Path, "/link/download/")]
		if !ok {
			http.NotFound(response, request)

			return
		}

		response.Write(body)
	}))
	t.Cleanup(server.Close)

	return server, asked
}

func TestCompareOrdersReleasedVersions(t *testing.T) {
	cases := []struct {
		a, b  string
		order int
		ok    bool
	}{
		{"0.2.0", "0.10.0", -1, true},
		{"1.0.0", "0.9.9", 1, true},
		{"0.3.1", "0.3.1", 0, true},
		{"dev", "0.3.1", 0, false},
		{"0.3", "0.3.1", 0, false},
		{"0.2.0+1a2b3c4", "0.2.0", 0, true},
		{"0.2.0+1a2b3c4", "0.2.0+9f8e7d6", 0, true},
		{"0.2.1", "0.2.0+1a2b3c4", 1, true},
		{"0.2.0+main", "0.2.0", 0, false},
	}

	for _, held := range cases {
		order, ok := Compare(held.a, held.b)
		if order != held.order || ok != held.ok {
			t.Errorf("Compare(%q, %q) = %d, %v", held.a, held.b, order, ok)
		}
	}
}

func TestAnOlderVersionNeedsXixoToSayItRollsBack(t *testing.T) {
	sha := strings.Repeat("a", 64)

	if err := Allowed("0.3.0", Target{Version: "0.2.0", SHA256: sha}); !errors.Is(err, ErrDowngrade) {
		t.Fatalf("an unannounced downgrade: %v", err)
	}

	if err := Allowed("0.3.0", Target{Version: "0.2.0", SHA256: sha, Downgrade: true}); err != nil {
		t.Fatalf("a rollback xixo named: %v", err)
	}

	if err := Allowed("dev", Target{Version: "0.2.0", SHA256: sha}); err != nil {
		t.Fatalf("a dev build: %v", err)
	}

	if err := Allowed("0.2.0", Target{Version: "0.2.0", SHA256: "ABC"}); !errors.Is(err, ErrUntold) {
		t.Fatalf("a malformed hash: %v", err)
	}

	if err := Allowed("0.2.0", Target{Version: "0.3.0; rm -rf /", SHA256: sha}); !errors.Is(err, ErrUntold) {
		t.Fatalf("a malformed version: %v", err)
	}

	if err := Allowed("0.2.0", Target{Version: "0.2.0+1a2b3c4", SHA256: sha}); err != nil {
		t.Fatalf("a build from main after the release it names: %v", err)
	}

	if err := Allowed("0.2.0+1a2b3c4", Target{Version: "0.2.0", SHA256: sha}); err != nil {
		t.Fatalf("the release a build from main is named after: %v", err)
	}
}

func TestFetchKeepsOnlyBytesThatMatchTheirHash(t *testing.T) {
	body := script("echo 0.3.0")
	server, _ := served(t, map[string][]byte{"xixo-link-linux-amd64": body})
	dir := t.TempDir()

	kept, err := Fetch(context.Background(), server.Client(), Address(server.URL, "xixo-link-linux-amd64"), sum(body), dir)
	if err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(kept)
	if err != nil || info.Mode().Perm() != 0o755 || filepath.Dir(kept) != dir {
		t.Fatalf("kept %s: %v %v", kept, info, err)
	}

	if _, err := Fetch(context.Background(), server.Client(), Address(server.URL, "xixo-link-linux-amd64"), strings.Repeat("0", 64), dir); !errors.Is(err, ErrMismatch) {
		t.Fatalf("a wrong hash: %v", err)
	}

	if _, err := Fetch(context.Background(), server.Client(), Address(server.URL, "xixo-link-linux-arm64"), sum(body), dir); err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("a missing build: %v", err)
	}

	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("a failed download left files behind: %v", entries)
	}
}

func TestProbeRunsTheNewBinary(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "xixo-link")
	os.WriteFile(path, script("echo 0.3.0"), 0o755)

	if err := Probe(context.Background(), path, "0.3.0"); err != nil {
		t.Fatal(err)
	}

	if err := Probe(context.Background(), path, "0.4.0"); err == nil {
		t.Fatal("a binary that names another version passed")
	}

	os.WriteFile(path, script("exit 3"), 0o755)

	if err := Probe(context.Background(), path, "0.3.0"); err == nil {
		t.Fatal("a binary that fails passed")
	}
}

func TestSwapKeepsThePreviousBinaryForRestore(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "xixo-link")
	fresh := filepath.Join(dir, "fresh")
	os.WriteFile(target, []byte("old"), 0o755)
	os.WriteFile(fresh, []byte("new"), 0o755)

	if err := Swap(fresh, target); err != nil {
		t.Fatal(err)
	}

	if held, _ := os.ReadFile(target); string(held) != "new" {
		t.Fatalf("target holds %q", held)
	}

	if held, _ := os.ReadFile(target + Previous); string(held) != "old" {
		t.Fatalf("previous holds %q", held)
	}

	if err := Restore(target); err != nil {
		t.Fatal(err)
	}

	if held, _ := os.ReadFile(target); string(held) != "old" {
		t.Fatalf("restored target holds %q", held)
	}
}

func TestReadRefusesALink(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "real.json"), []byte(`{"version":"0.3.0"}`), 0o644)
	os.Symlink(filepath.Join(dir, "real.json"), filepath.Join(dir, RequestFile))

	if err := Read(filepath.Join(dir, RequestFile), &Request{}); err == nil {
		t.Fatal("read through a symbolic link")
	}

	os.WriteFile(filepath.Join(dir, "big.json"), []byte(strings.Repeat(" ", mostRecord+1)), 0o644)

	if err := Read(filepath.Join(dir, "big.json"), &Request{}); err == nil {
		t.Fatal("read a file larger than a record")
	}
}

func TestARequestIsMadeOnceUntilItIsRetried(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)
	self := Self{Version: "0.2.0", SHA256: strings.Repeat("1", 64)}
	asking := &Requester{Dir: dir, Self: self, Now: func() time.Time { return now }}
	target := Target{Version: "0.3.0", SHA256: strings.Repeat("2", 64)}

	if err := asking.Offer(context.Background(), target); err != nil {
		t.Fatal(err)
	}

	held := Request{}
	if err := Read(filepath.Join(dir, RequestFile), &held); err != nil || held.SHA256 != target.SHA256 || held.From != "0.2.0" {
		t.Fatalf("request %+v: %v", held, err)
	}

	info, _ := os.Stat(filepath.Join(dir, RequestFile))
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("the request is mode %o", info.Mode().Perm())
	}

	if len(asking.Warnings()) != 0 {
		t.Fatalf("a request in flight warned: %v", asking.Warnings())
	}

	now = now.Add(InFlight + time.Minute)

	if err := asking.Offer(context.Background(), target); err != nil {
		t.Fatal(err)
	}

	again := Request{}
	Read(filepath.Join(dir, RequestFile), &again)

	if !again.RequestedAt.Equal(held.RequestedAt) {
		t.Fatal("a failed request was made again before it was due")
	}

	warned := asking.Warnings()
	if len(warned) != 1 || !strings.Contains(warned[0], "could not update to 0.3.0 and still runs 0.2.0") {
		t.Fatalf("warnings %v", warned)
	}

	now = now.Add(Retry)

	if err := asking.Offer(context.Background(), target); err != nil {
		t.Fatal(err)
	}

	Read(filepath.Join(dir, RequestFile), &again)

	if again.RequestedAt.Equal(held.RequestedAt) {
		t.Fatal("a failed request was not made again once due")
	}
}

func TestACurrentLinkAsksForNothing(t *testing.T) {
	dir := t.TempDir()
	sha := strings.Repeat("1", 64)
	asking := &Requester{Dir: dir, Self: Self{Version: "0.3.0", SHA256: sha}}

	if err := asking.Offer(context.Background(), Target{Version: "0.3.0", SHA256: sha}); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(dir, RequestFile)); !os.IsNotExist(err) {
		t.Fatalf("a current link made a request: %v", err)
	}

	if err := asking.Offer(context.Background(), Target{Version: "0.2.0", SHA256: strings.Repeat("2", 64)}); !errors.Is(err, ErrDowngrade) {
		t.Fatalf("an unannounced downgrade: %v", err)
	}
}

func applying(t *testing.T, fresh []byte, connects bool) (*Updater, string, string) {
	t.Helper()

	server, _ := served(t, map[string][]byte{"xixo-link-linux-amd64": fresh})
	requests := t.TempDir()
	results := t.TempDir()
	binary := filepath.Join(t.TempDir(), "xixo-link")
	os.WriteFile(binary, script("echo 0.2.0"), 0o755)

	Write(filepath.Join(requests, RequestFile), Request{
		Target: Target{Version: "0.3.0", SHA256: sum(fresh)}, From: "0.2.0", RequestedAt: time.Now().UTC(),
	}, 0o644)

	if connects {
		go func() {
			deadline := time.Now().Add(5 * time.Second)

			for time.Now().Before(deadline) {
				if held, _ := Digest(binary); held == sum(fresh) {
					Write(filepath.Join(requests, RunningFile), Running{Version: "0.3.0", SHA256: held, PID: 1, At: time.Now().UTC()}, 0o644)

					return
				}

				time.Sleep(10 * time.Millisecond)
			}
		}()
	}

	return &Updater{
		Xixo: server.URL, Requests: requests, Results: results, Binary: binary, Build: "xixo-link-linux-amd64",
		Client: server.Client(), Wait: 500 * time.Millisecond, Poll: 20 * time.Millisecond,
	}, binary, results
}

func TestTheUpdaterInstallsAVerifiedBinaryThatConnects(t *testing.T) {
	fresh := script("echo 0.3.0")
	updater, binary, results := applying(t, fresh, true)

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held, _ := Digest(binary); held != sum(fresh) {
		t.Fatal("the new binary is not in place")
	}

	told := Result{}
	if err := Read(filepath.Join(results, ResultFile), &told); err != nil || !told.OK || told.Version != "0.3.0" {
		t.Fatalf("result %+v: %v", told, err)
	}

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatalf("applying a request already in place: %v", err)
	}
}

func TestTheUpdaterPutsThePreviousBinaryBackWhenTheNewOneDoesNotConnect(t *testing.T) {
	fresh := script("echo 0.3.0")
	updater, binary, results := applying(t, fresh, false)

	err := updater.Apply(context.Background())
	if err == nil || !strings.Contains(err.Error(), "went back to 0.2.0") {
		t.Fatalf("apply: %v", err)
	}

	if held, _ := os.ReadFile(binary); string(held) != string(script("echo 0.2.0")) {
		t.Fatalf("the binary holds %q", held)
	}

	told := Result{}
	if Read(filepath.Join(results, ResultFile), &told); told.OK || !strings.Contains(told.Error, "did not connect") {
		t.Fatalf("result %+v", told)
	}

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatalf("a request that failed once was tried again: %v", err)
	}

	if held, _ := os.ReadFile(binary); string(held) != string(script("echo 0.2.0")) {
		t.Fatal("a request that failed once was installed again")
	}
}

func TestTheUpdaterRefusesBytesThatDoNotMatch(t *testing.T) {
	updater, binary, _ := applying(t, script("echo 0.3.0"), false)
	Write(filepath.Join(updater.Requests, RequestFile), Request{
		Target: Target{Version: "0.3.0", SHA256: strings.Repeat("9", 64)}, From: "0.2.0", RequestedAt: time.Now().UTC(),
	}, 0o644)

	if err := updater.Apply(context.Background()); !errors.Is(err, ErrMismatch) {
		t.Fatalf("apply: %v", err)
	}

	if held, _ := os.ReadFile(binary); string(held) != string(script("echo 0.2.0")) {
		t.Fatal("a mismatched download replaced the binary")
	}
}

func TestTheUpdaterRefusesABinaryThatDoesNotStart(t *testing.T) {
	updater, binary, _ := applying(t, script("echo 0.2.9"), true)

	if err := updater.Apply(context.Background()); err == nil || !strings.Contains(err.Error(), "says it is") {
		t.Fatalf("apply: %v", err)
	}

	if held, _ := os.ReadFile(binary); string(held) != string(script("echo 0.2.0")) {
		t.Fatal("a binary that failed its probe replaced the old one")
	}
}

func TestReplacedNoticesANewBinary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "xixo-link")
	os.WriteFile(path, []byte("old"), 0o755)

	go func() {
		time.Sleep(50 * time.Millisecond)
		fresh := path + ".fresh"
		os.WriteFile(fresh, []byte("newer"), 0o755)
		os.Rename(fresh, path)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if !Replaced(ctx, path, 10*time.Millisecond) {
		t.Fatal("a replaced binary went unnoticed")
	}
}
