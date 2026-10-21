package parts

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

func TestMain(m *testing.M) {
	if os.Getenv("XIXO_FAKE_PART") != "" {
		fakePart()

		return
	}

	os.Exit(m.Run())
}

func fakePart() {
	listener, err := net.Listen("tcp", strings.TrimPrefix(os.Getenv("OLLAMA_HOST"), "http://"))
	if err != nil {
		os.Exit(2)
	}

	if os.Getenv("XIXO_FAKE_PART") == "broken" {
		time.Sleep(200 * time.Millisecond)
		os.Exit(3)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/version", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"version":"fake"}`) })
	mux.HandleFunc("/api/pull", func(w http.ResponseWriter, r *http.Request) {
		asked := map[string]any{}
		json.NewDecoder(r.Body).Decode(&asked)

		if asked["name"] == "missing:latest" {
			fmt.Fprintln(w, `{"error":"pull model manifest: file does not exist"}`)

			return
		}

		fmt.Fprintln(w, `{"status":"pulling","total":100,"completed":40}`)
		fmt.Fprintln(w, `{"status":"pulling","total":100,"completed":100}`)
		fmt.Fprintln(w, `{"status":"success"}`)
	})

	server := &http.Server{Handler: mux}
	go server.Serve(listener)

	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, os.Interrupt)
	<-stopped
	server.Close()
	os.Exit(0)
}

func archived(t *testing.T, kind string, files map[string]string) ([]byte, string) {
	t.Helper()
	raw := &bytes.Buffer{}

	var compressed io.WriteCloser
	if kind == ArchiveZstd {
		encoder, err := zstd.NewWriter(raw)
		if err != nil {
			t.Fatal(err)
		}

		compressed = encoder
	} else {
		compressed = gzipWriter(raw)
	}

	writer := tar.NewWriter(compressed)
	for name, body := range files {
		if strings.HasPrefix(body, "-> ") {
			writer.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeSymlink, Linkname: strings.TrimPrefix(body, "-> ")})

			continue
		}

		mode := int64(0o644)
		if strings.HasSuffix(name, "/ollama") || name == "ollama" {
			mode = 0o755
		}

		writer.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(body)), Typeflag: tar.TypeReg})
		writer.Write([]byte(body))
	}

	writer.Close()
	compressed.Close()

	sum := sha256.Sum256(raw.Bytes())

	return raw.Bytes(), hex.EncodeToString(sum[:])
}

func serving(t *testing.T, body []byte, ranges bool) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ranges {
			http.ServeContent(w, r, "build", time.Time{}, bytes.NewReader(body))

			return
		}

		w.Write(body)
	}))
	t.Cleanup(server.Close)

	return server
}

func TestFetchChecksTheHashAndUnpacksSafely(t *testing.T) {
	body, sum := archived(t, ArchiveZstd, map[string]string{
		"./bin/ollama": "#!/bin/sh\necho hi", "lib/ollama/libggml.so.1": "lib", "lib/ollama/libggml.so": "-> libggml.so.1",
	})
	server := serving(t, body, true)
	dir := t.TempDir()

	archive, err := Fetch(context.Background(), server.Client(), Build{URL: server.URL, SHA256: sum, Archive: ArchiveZstd}, dir)
	if err != nil {
		t.Fatal(err)
	}

	if err := Unpack(archive, ArchiveZstd, filepath.Join(dir, "v")); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(filepath.Join(dir, "v", "bin", "ollama"))
	if err != nil || info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("bin/ollama %v %v", info, err)
	}

	if linked, _ := os.Readlink(filepath.Join(dir, "v", "lib", "ollama", "libggml.so")); linked != "libggml.so.1" {
		t.Fatalf("symlink %q", linked)
	}

	if _, err := Fetch(context.Background(), server.Client(), Build{URL: server.URL, SHA256: strings.Repeat("0", 64), Archive: ArchiveZstd}, dir); !errors.Is(err, ErrMismatch) {
		t.Fatalf("a wrong hash: %v", err)
	}

	escaping, escapingSum := archived(t, ArchiveGzip, map[string]string{"../evil": "x"})
	evil := serving(t, escaping, false)
	archive, err = Fetch(context.Background(), evil.Client(), Build{URL: evil.URL, SHA256: escapingSum, Archive: ArchiveGzip}, dir)
	if err != nil {
		t.Fatal(err)
	}

	if err := Unpack(archive, ArchiveGzip, filepath.Join(dir, "e")); !errors.Is(err, ErrEscapes) {
		t.Fatalf("an escaping path unpacked: %v", err)
	}

	linking, linkingSum := archived(t, ArchiveGzip, map[string]string{"lib/out": "-> ../../etc/passwd"})
	links := serving(t, linking, false)
	archive, err = Fetch(context.Background(), links.Client(), Build{URL: links.URL, SHA256: linkingSum, Archive: ArchiveGzip}, dir)
	if err != nil {
		t.Fatal(err)
	}

	if err := Unpack(archive, ArchiveGzip, filepath.Join(dir, "l")); !errors.Is(err, ErrEscapes) {
		t.Fatalf("an escaping symlink unpacked: %v", err)
	}
}

func TestFetchResumesADownloadThatStopped(t *testing.T) {
	noise := make([]byte, 20000)
	for index := range noise {
		noise[index] = byte(index*7919 + index/3)
	}

	body, sum := archived(t, ArchiveGzip, map[string]string{"ollama": string(noise)})
	server := serving(t, body, true)
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, sum[:16]+suffix), body[:len(body)/2], 0o644)

	var got *http.Request
	client := &http.Client{Transport: roundTripper(func(r *http.Request) (*http.Response, error) {
		got = r

		return server.Client().Transport.RoundTrip(r)
	})}

	if _, err := Fetch(context.Background(), client, Build{URL: server.URL, SHA256: sum, Archive: ArchiveGzip}, dir); err != nil {
		t.Fatal(err)
	}

	if got == nil || got.Header.Get("Range") != "bytes="+strconv.Itoa(len(body)/2)+"-" {
		t.Fatalf("range %v", got)
	}
}

type roundTripper func(*http.Request) (*http.Response, error)

func (f roundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func fakeRunner(t *testing.T, mode string) (*Runner, Build, string) {
	t.Helper()
	body, sum := archived(t, ArchiveGzip, map[string]string{"ollama": "not run"})
	server := serving(t, body, true)
	root := t.TempDir()
	build := Build{URL: server.URL, SHA256: sum, Archive: ArchiveGzip, Command: "ollama"}
	recipe := Recipe{Name: "models", Version: "1.0.0", Health: "/api/version", Args: []string{"serve"}, Builds: map[string]Build{}}

	for _, system := range []string{"linux-amd64", "linux-arm64", "darwin-arm64", "darwin-amd64"} {
		recipe.Builds[system] = build
	}

	held := &Runner{
		Recipe:   recipe,
		Releases: filepath.Join(root, "releases"),
		Wanted:   filepath.Join(root, "wanted.json"),
		State:    filepath.Join(root, "state"),
		Status:   filepath.Join(root, "status.json"),
		Client:   server.Client(),
		Watching: 50 * time.Millisecond,
		Command: func(ctx context.Context, program string, args, env []string) *exec.Cmd {
			command := exec.CommandContext(ctx, os.Args[0], "-test.run=TestMain")
			command.Env = append(env, "XIXO_FAKE_PART="+mode, "XIXO_FAKE_PROGRAM="+program)
			command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
			command.WaitDelay = Stopping

			return command
		},
	}

	return held, build, root
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	return listener.Addr().(*net.TCPAddr).Port
}

func statusOf(t *testing.T, held *Runner) Status {
	t.Helper()
	status, err := ReadStatus(held.Status)
	if err != nil {
		t.Fatal(err)
	}

	return status
}

func TestAPartIsFetchedStartedCheckedAndStopsWhenNoLongerWanted(t *testing.T) {
	held, _, root := fakeRunner(t, "ok")
	port := freePort(t)
	WriteWanted(held.Wanted, Wanted{Version: "1.0.0", Settings: Settings{Port: port, Models: []string{"nomic-embed-text", "missing:latest"}}})

	finished := make(chan error, 1)
	go func() { finished <- held.Run(context.Background()) }()

	deadline := time.Now().Add(20 * time.Second)
	for {
		status, _ := ReadStatus(held.Status)
		if status.State == StateRunning && len(status.Pulls) == 2 && status.Pulls[1].Error != "" {
			break
		}

		if time.Now().After(deadline) {
			t.Fatalf("status %+v", status)
		}

		time.Sleep(50 * time.Millisecond)
	}

	status := statusOf(t, held)
	if status.Port != port || status.Version != "1.0.0" || !status.Pulls[0].Ready || status.Pulls[0].Done != 100 {
		t.Fatalf("status %+v", status)
	}

	if pointed(held.Releases, Current) != "1.0.0" || pointed(held.Releases, Good) != "1.0.0" {
		t.Fatalf("current %q good %q", pointed(held.Releases, Current), pointed(held.Releases, Good))
	}

	if _, err := os.Stat(filepath.Join(root, "releases", "1.0.0", "ollama")); err != nil {
		t.Fatal(err)
	}

	if info, err := os.Stat(held.State); err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("state %v %v", info, err)
	}

	Unwant(held.Wanted)

	select {
	case err := <-finished:
		if err != nil {
			t.Fatalf("run ended with %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the part did not stop once unwanted")
	}

	if status := statusOf(t, held); status.State != StateStopped {
		t.Fatalf("status %+v", status)
	}
}

func TestAPartThatFailsItsHealthCheckGoesBackToTheGoodVersion(t *testing.T) {
	held, _, _ := fakeRunner(t, "broken")
	port := freePort(t)
	WriteWanted(held.Wanted, Wanted{Version: "1.0.0", Settings: Settings{Port: port}})

	before := Probation
	setProbation(100 * time.Millisecond)
	t.Cleanup(func() { setProbation(before) })

	err := held.Run(context.Background())
	if !errors.Is(err, ErrExited) && !errors.Is(err, ErrUnhealthy) {
		t.Fatalf("a broken part ran: %v", err)
	}

	if status := statusOf(t, held); status.State != StateFailed || status.Warning == "" {
		t.Fatalf("status %+v", status)
	}

	os.MkdirAll(filepath.Join(held.Releases, "0.9.0"), 0o755)
	os.WriteFile(filepath.Join(held.Releases, "0.9.0", "ollama"), []byte("old"), 0o755)
	point(held.Releases, Good, "0.9.0")

	held.Command = func(ctx context.Context, program string, args, env []string) *exec.Cmd {
		mode := "ok"
		if strings.Contains(program, "1.0.0") {
			mode = "broken"
		}

		command := exec.CommandContext(ctx, os.Args[0], "-test.run=TestMain")
		command.Env = append(env, "XIXO_FAKE_PART="+mode)
		command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }

		return command
	}

	finished := make(chan error, 1)
	go func() { finished <- held.Run(context.Background()) }()

	deadline := time.Now().Add(20 * time.Second)
	for {
		status, _ := ReadStatus(held.Status)
		if status.State == StateRunning {
			break
		}

		if time.Now().After(deadline) {
			t.Fatalf("status %+v", status)
		}

		time.Sleep(50 * time.Millisecond)
	}

	if pointed(held.Releases, Current) != "0.9.0" || statusOf(t, held).Version != "0.9.0" {
		t.Fatalf("current %q, status %+v", pointed(held.Releases, Current), statusOf(t, held))
	}

	Unwant(held.Wanted)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
}

func TestAPartStartedByAnOlderLinkStartsAgain(t *testing.T) {
	held, _, _ := fakeRunner(t, "ok")
	WriteWanted(held.Wanted, Wanted{Version: "2.0.0"})

	if err := held.Run(context.Background()); !errors.Is(err, ErrStale) {
		t.Fatalf("got %v", err)
	}

	Unwant(held.Wanted)

	if err := held.Run(context.Background()); err != nil || statusOf(t, held).State != StateStopped {
		t.Fatalf("an unwanted part: %v %+v", err, statusOf(t, held))
	}
}
