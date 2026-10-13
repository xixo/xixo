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
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	Restart    = 75
	MostBinary = 256 << 20
	mostRecord = 4096
	Binary     = "xixo-link"
	MacReader  = "xixo-mac-reader"
	Previous   = ".previous"
	Fetching   = 10 * time.Minute
)

var (
	released = regexp.MustCompile(`^\d{1,6}\.\d{1,6}\.\d{1,6}$`)
	hexed    = regexp.MustCompile(`^[0-9a-f]{64}$`)

	ErrMismatch  = errors.New("the download did not match the SHA-256 xixo sent")
	ErrDowngrade = errors.New("xixo named an older version without saying it is rolling back")
	ErrTooLarge  = errors.New("the download is larger than xixo link accepts")
	ErrUntold    = errors.New("xixo named no version and SHA-256 xixo link can use")
)

type Target struct {
	Version   string `json:"version"`
	SHA256    string `json:"sha256"`
	Downgrade bool   `json:"downgrade,omitempty"`
	MacReader string `json:"mac_reader,omitempty"`
}

func (t Target) Check() error {
	if !released.MatchString(t.Version) || !hexed.MatchString(t.SHA256) {
		return ErrUntold
	}

	if t.MacReader != "" && !hexed.MatchString(t.MacReader) {
		return ErrUntold
	}

	return nil
}

type Request struct {
	Target
	From        string    `json:"from"`
	RequestedAt time.Time `json:"requested_at"`
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

func Compare(a, b string) (int, bool) {
	left, ok := parts(a)
	if !ok {
		return 0, false
	}

	right, ok := parts(b)
	if !ok {
		return 0, false
	}

	for i := range left {
		switch {
		case left[i] < right[i]:
			return -1, true
		case left[i] > right[i]:
			return 1, true
		}
	}

	return 0, true
}

func parts(version string) ([3]int, bool) {
	held := [3]int{}
	if !released.MatchString(version) {
		return held, false
	}

	for i, part := range strings.Split(version, ".") {
		held[i], _ = strconv.Atoi(part)
	}

	return held, true
}

func Allowed(running string, target Target) error {
	if err := target.Check(); err != nil {
		return err
	}

	if order, ok := Compare(target.Version, running); ok && order < 0 && !target.Downgrade {
		return fmt.Errorf("%w: it runs %s and xixo named %s", ErrDowngrade, running, target.Version)
	}

	return nil
}

func Digest(path string) (string, error) {
	opened, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer opened.Close()

	hashed := sha256.New()
	if _, err := io.Copy(hashed, opened); err != nil {
		return "", err
	}

	return hex.EncodeToString(hashed.Sum(nil)), nil
}

func Address(xixo, file string) string {
	return strings.TrimSuffix(xixo, "/") + "/link/download/" + file
}

func BuildFor(goos, goarch string) string {
	return Binary + "-" + goos + "-" + goarch
}

func Fetch(ctx context.Context, client *http.Client, address, sum, dir string) (string, error) {
	if !hexed.MatchString(sum) {
		return "", ErrUntold
	}

	ctx, cancel := context.WithTimeout(ctx, Fetching)
	defer cancel()

	if !strings.HasPrefix(address, "https://") && !strings.HasPrefix(address, "http://") {
		return "", fmt.Errorf("xixo link downloads only over http or https, not from %s", address)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}

	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("xixo answered the download with %s", response.Status)
	}

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
