package update

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xixo/xixo/link/internal/release"
)

const (
	Current = "current"
	Good    = "good"
)

var releaseName = regexp.MustCompile(`^[0-9a-f]{16}$`)

func ReleaseName(target Target) string {
	return target.SHA256[:16]
}

type Stager struct {
	Xixo       string
	Releases   string
	State      string
	Self       Self
	Client     *http.Client
	OS         string
	Arch       string
	Restart    func()
	Now        func() time.Time
	Retry      time.Duration
	Vouch      *Vouch
	Home       string
	Agent      string
	Supervisor string
	Relaunch   func(context.Context) error
	once       sync.Once
	ledger     *ledger
	busy       sync.Mutex
}

func (s *Stager) book() *ledger {
	s.once.Do(func() {
		s.ledger = &ledger{Path: filepath.Join(s.State, RequestFile), Mode: 0o600, Now: s.Now, Retry: s.Retry}
	})

	return s.ledger
}

func (s *Stager) Offer(ctx context.Context, target Target) error {
	if !s.busy.TryLock() {
		return nil
	}
	defer s.busy.Unlock()

	claimed, err := s.book().claim(s.Self, target)
	if err != nil || !claimed {
		return err
	}

	relaunch, err := s.stage(ctx, target)
	if err != nil {
		Write(filepath.Join(s.State, ResultFile), Result{Version: target.Version, SHA256: target.SHA256, Error: err.Error(), At: time.Now().UTC()}, 0o600)

		return err
	}

	if relaunch && s.Relaunch != nil {
		return s.Relaunch(ctx)
	}

	if s.Restart != nil {
		s.Restart()
	}

	return nil
}

func (s *Stager) Mode() string { return "self" }

func (s *Stager) RollBack(_ context.Context, target Target) error {
	if !s.busy.TryLock() {
		return nil
	}
	defer s.busy.Unlock()

	claimed, err := s.book().ask(s.Self, target, true)
	if err != nil || !claimed {
		return err
	}

	name := ReleaseName(target)

	sha, err := Digest(filepath.Join(s.Releases, name, Binary))
	if err != nil || sha != target.SHA256 {
		err = fmt.Errorf("this machine does not hold version %s", target.Version)
		Write(filepath.Join(s.State, ResultFile), Result{Version: target.Version, SHA256: target.SHA256, Error: err.Error(), At: time.Now().UTC()}, 0o600)

		return err
	}

	if err := Point(s.Releases, Current, name); err != nil {
		return err
	}

	if s.Restart != nil {
		s.Restart()
	}

	return nil
}

func (s *Stager) Report() Report {
	return Report{Result: lastResult(s.State), Held: heldIn(s.Releases)}
}

func (s *Stager) Warnings() []string {
	return s.book().warnings(s.Self, s.State)
}

func (s *Stager) Connected() error {
	return Write(filepath.Join(s.State, RunningFile), running(s.Self), 0o600)
}

func (s *Stager) system() (string, string) {
	return system(s.OS, s.Arch)
}

func system(goos, goarch string) (string, string) {
	if goos == "" {
		goos = runtime.GOOS
	}

	if goarch == "" {
		goarch = runtime.GOARCH
	}

	return goos, goarch
}

func (s *Stager) stage(ctx context.Context, target Target) (bool, error) {
	if err := os.MkdirAll(s.Releases, 0o700); err != nil {
		return false, err
	}

	part, err := os.MkdirTemp(s.Releases, ".part-")
	if err != nil {
		return false, err
	}
	defer os.RemoveAll(part)

	goos, goarch := s.system()

	signed, err := s.Vouch.Release(ctx, target, goos, goarch)
	if err != nil {
		return false, err
	}

	if err := os.WriteFile(filepath.Join(part, release.File), signed.Raw, 0o600); err != nil {
		return false, err
	}

	fetched, err := Fetch(ctx, s.Client, Address(s.Xixo, BuildFor(goos, goarch)), target.SHA256, part)
	if err != nil {
		return false, err
	}

	if err := os.Rename(fetched, filepath.Join(part, Binary)); err != nil {
		return false, err
	}

	if err := s.reader(ctx, target, part); err != nil {
		return false, err
	}

	agent, err := s.agent(ctx, signed, part)
	if err != nil {
		return false, err
	}

	if signed.Serial > 0 {
		if err := Write(filepath.Join(part, FloorFile), signed.Serial, 0o600); err != nil {
			return false, err
		}
	}

	if err := Probe(ctx, filepath.Join(part, Binary), target.Version); err != nil {
		return false, err
	}

	name := ReleaseName(target)
	placed := filepath.Join(s.Releases, name)
	running := Pointed(s.Releases, Current)

	if err := os.RemoveAll(placed); err != nil {
		return false, err
	}

	if err := os.Rename(part, placed); err != nil {
		return false, err
	}

	if err := Point(s.Releases, Current, name); err != nil {
		return false, err
	}

	Prune(s.Releases, running)

	supervisor, err := s.supervisor(ctx, signed, filepath.Join(placed, Binary))
	if err != nil {
		return false, err
	}

	if agent != nil {
		if err := replaced(s.Agent, agent, 0o644); err != nil {
			return false, err
		}
	}

	return agent != nil || supervisor, nil
}

func (s *Stager) agent(ctx context.Context, signed Verified, part string) ([]byte, error) {
	entry, ok := signed.LaunchAgent()
	if !ok || s.Agent == "" {
		return nil, nil
	}

	fetched, err := Fetch(ctx, s.Client, Address(s.Xixo, entry.Name), entry.SHA256, part)
	if err != nil {
		return nil, fmt.Errorf("the launch agent: %w", err)
	}

	raw, err := os.ReadFile(fetched)
	if err != nil {
		return nil, err
	}

	rendered := []byte(strings.ReplaceAll(string(raw), "@HOME@", s.Home))
	if installed, err := os.ReadFile(s.Agent); err == nil && bytes.Equal(installed, rendered) {
		return nil, nil
	}

	return rendered, nil
}

func (s *Stager) supervisor(ctx context.Context, signed Verified, binary string) (bool, error) {
	if s.Supervisor == "" || signed.SupervisorEpoch <= s.epoch(ctx) {
		return false, nil
	}

	raw, err := os.ReadFile(binary)
	if err != nil {
		return false, err
	}

	return true, replaced(s.Supervisor, raw, 0o755)
}

func (s *Stager) epoch(ctx context.Context) int64 {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, s.Supervisor, "epoch").Output()
	if err != nil {
		return 0
	}

	held, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 0
	}

	return held
}

func (s *Stager) reader(ctx context.Context, target Target, part string) error {
	if target.MacReader != "" {
		fetched, err := Fetch(ctx, s.Client, Address(s.Xixo, MacReader), target.MacReader, part)
		if err != nil {
			return fmt.Errorf("the mac reader: %w", err)
		}

		return os.Rename(fetched, filepath.Join(part, MacReader))
	}

	self, err := os.Executable()
	if err != nil {
		return nil
	}

	if real, err := filepath.EvalSymlinks(self); err == nil {
		self = real
	}

	return copied(filepath.Join(filepath.Dir(self), MacReader), filepath.Join(part, MacReader))
}

func copied(from, to string) error {
	if !regular(from) {
		return nil
	}

	source, err := os.Open(from)
	if err != nil {
		return err
	}
	defer source.Close()

	kept, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o755)
	if err != nil {
		return err
	}

	if _, err := io.Copy(kept, source); err != nil {
		kept.Close()

		return err
	}

	return kept.Close()
}

func Point(releases, pointer, name string) error {
	if !releaseName.MatchString(name) {
		return fmt.Errorf("%q is not a release xixo link keeps", name)
	}

	path := filepath.Join(releases, pointer)
	fresh := path + ".part"
	os.Remove(fresh)

	if err := os.Symlink(name, fresh); err != nil {
		return err
	}

	if err := os.Rename(fresh, path); err != nil {
		os.Remove(fresh)

		return err
	}

	return syncDir(releases)
}

func Pointed(releases, pointer string) string {
	name, err := os.Readlink(filepath.Join(releases, pointer))
	if err != nil || !releaseName.MatchString(name) {
		return ""
	}

	if !regular(filepath.Join(releases, name, Binary)) {
		return ""
	}

	return name
}

func Unpoint(releases, pointer string) error {
	err := os.Remove(filepath.Join(releases, pointer))
	if err != nil && !missing(err) {
		return err
	}

	return nil
}

func Prune(releases string, keep ...string) {
	kept := map[string]bool{Pointed(releases, Current): true, Pointed(releases, Good): true}
	for _, name := range keep {
		kept[name] = true
	}

	entries, err := os.ReadDir(releases)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if releaseName.MatchString(entry.Name()) && !kept[entry.Name()] {
			os.RemoveAll(filepath.Join(releases, entry.Name()))
		}
	}
}
