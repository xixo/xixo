package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/xixo/xixo/link/internal/release"
)

const (
	Interrupted = 130
	Restart     = 75
	MostBinary  = 256 << 20
	mostRecord  = 4096
	Binary      = "xixo-link"
	MacReader   = release.MacReader
	Previous    = ".previous"
	Fetching    = 10 * time.Minute
)

var (
	ErrMismatch = errors.New("the download did not match the SHA-256 xixo sent")
	ErrTooLarge = errors.New("the download is larger than xixo link accepts")
	ErrUntold   = errors.New("xixo named no version and SHA-256 xixo link can use")
)

type Target struct {
	Version   string `json:"version"`
	SHA256    string `json:"sha256"`
	MacReader string `json:"mac_reader,omitempty"`
	Release   string `json:"release,omitempty"`
}

func (t Target) Check() error {
	if !release.Versioned.MatchString(t.Version) || !release.Hexed.MatchString(t.SHA256) {
		return ErrUntold
	}

	if t.MacReader != "" && !release.Hexed.MatchString(t.MacReader) {
		return ErrUntold
	}

	if t.Release != "" && !release.Hexed.MatchString(t.Release) {
		return ErrUntold
	}

	return nil
}

type Request struct {
	Target
	From        string    `json:"from"`
	RequestedAt time.Time `json:"requested_at"`
	RollBack    bool      `json:"roll_back,omitempty"`
}

type Held struct {
	Release  string `json:"release"`
	Version  string `json:"version"`
	Serial   int64  `json:"serial"`
	Protocol int64  `json:"protocol"`
	SHA256   string `json:"sha256"`
}

type Report struct {
	Result *Result
	Held   []Held
}

type Running struct {
	Version string    `json:"version"`
	SHA256  string    `json:"sha256"`
	PID     int       `json:"pid"`
	At      time.Time `json:"at"`
}

type Result struct {
	Version     string    `json:"version"`
	SHA256      string    `json:"sha256"`
	RequestedAt time.Time `json:"requested_at"`
	OK          bool      `json:"ok"`
	Error       string    `json:"error,omitempty"`
	At          time.Time `json:"at"`
}

const (
	RequestFile = "update.json"
	RunningFile = "running.json"
	ResultFile  = "result.json"
)

func Digest(path string) (string, error) {
	held, _, err := release.Digest(path)

	return held, err
}

func Address(xixo, file string) string {
	return strings.TrimSuffix(xixo, "/") + "/link/download/" + file
}

func BuildFor(goos, goarch string) string {
	return Binary + "-" + goos + "-" + goarch
}

func get(ctx context.Context, client *http.Client, address string) (*http.Response, error) {
	if !strings.HasPrefix(address, "https://") && !strings.HasPrefix(address, "http://") {
		return nil, fmt.Errorf("xixo link downloads only over http or https, not from %s", address)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}

	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}

	if response.StatusCode == http.StatusNotFound {
		response.Body.Close()
		return nil, notFound{file: path.Base(address)}
	}

	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		return nil, fmt.Errorf("xixo answered %s with %s", path.Base(address), response.Status)
	}

	return response, nil
}

func Fetch(ctx context.Context, client *http.Client, address, sum, dir string) (string, error) {
	if !release.Hexed.MatchString(sum) {
		return "", ErrUntold
	}

	ctx, cancel := context.WithTimeout(ctx, Fetching)
	defer cancel()

	response, err := get(ctx, client, address)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	if response.ContentLength > MostBinary {
		return "", ErrTooLarge
	}

	kept, err := os.CreateTemp(dir, ".xixo-update-*")
	if err != nil {
		return "", err
	}

	done := false
	defer func() {
		if !done {
			kept.Close()
			os.Remove(kept.Name())
		}
	}()

	hashed := sha256.New()
	written, err := io.Copy(io.MultiWriter(kept, hashed), io.LimitReader(response.Body, MostBinary+1))
	if err != nil {
		return "", err
	}

	if written > MostBinary {
		return "", ErrTooLarge
	}

	if hex.EncodeToString(hashed.Sum(nil)) != sum {
		return "", ErrMismatch
	}

	if err := kept.Chmod(0o755); err != nil {
		return "", err
	}

	if err := kept.Sync(); err != nil {
		return "", err
	}

	if err := kept.Close(); err != nil {
		return "", err
	}

	done = true

	return kept.Name(), nil
}

func Probe(ctx context.Context, path, version string) error {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	command := exec.CommandContext(ctx, path, "version")
	command.Env = []string{"PATH=/usr/bin:/bin"}

	said, err := command.Output()
	if err != nil {
		return fmt.Errorf("the new xixo link did not start: %w", err)
	}

	if strings.TrimSpace(string(said)) != version {
		return fmt.Errorf("the new xixo link says it is %q, and xixo named %s", strings.TrimSpace(string(said)), version)
	}

	return nil
}

func Swap(fresh, target string) error {
	previous := target + Previous

	if _, err := os.Lstat(target); err == nil {
		kept := previous + ".part"
		os.Remove(kept)

		if err := os.Link(target, kept); err != nil {
			return err
		}

		if err := os.Rename(kept, previous); err != nil {
			os.Remove(kept)

			return err
		}
	}

	if err := os.Rename(fresh, target); err != nil {
		return err
	}

	return syncDir(filepath.Dir(target))
}

func Restore(target string) error {
	if err := os.Rename(target+Previous, target); err != nil {
		return err
	}

	return syncDir(filepath.Dir(target))
}

func syncDir(dir string) error {
	opened, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer opened.Close()

	return opened.Sync()
}

func Write(path string, value any, mode os.FileMode) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}

	kept, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}

	_, err = kept.Write(append(encoded, '\n'))
	if err == nil {
		err = kept.Chmod(mode)
	}

	if err == nil {
		err = kept.Sync()
	}

	if closed := kept.Close(); err == nil {
		err = closed
	}

	if err == nil {
		err = os.Rename(kept.Name(), path)
	}

	if err != nil {
		os.Remove(kept.Name())
	}

	return err
}

func Read(path string, into any) error {
	opened, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer opened.Close()

	info, err := opened.Stat()
	if err != nil {
		return err
	}

	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", path)
	}

	raw, err := io.ReadAll(io.LimitReader(opened, mostRecord+1))
	if err != nil {
		return err
	}

	if len(raw) > mostRecord {
		return fmt.Errorf("%s is larger than %d bytes", path, mostRecord)
	}

	return json.Unmarshal(raw, into)
}
