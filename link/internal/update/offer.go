package update

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	InFlight = 10 * time.Minute
	Retry    = 6 * time.Hour
)

type Self struct {
	Version   string
	SHA256    string
	MacReader string
}

func Identify(version string) Self {
	held := Self{Version: version}

	path, err := os.Executable()
	if err != nil {
		return held
	}

	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}

	held.SHA256, _ = Digest(path)

	if reader := filepath.Join(filepath.Dir(path), MacReader); regular(reader) {
		held.MacReader, _ = Digest(reader)
	}

	return held
}

func (s Self) Needs(target Target) bool {
	return target.SHA256 != s.SHA256 || (target.MacReader != "" && target.MacReader != s.MacReader)
}

func (s Self) Matches(request Request) bool {
	return request.SHA256 == s.SHA256 && (request.MacReader == "" || request.MacReader == s.MacReader)
}

type ledger struct {
	Path  string
	Mode  os.FileMode
	Now   func() time.Time
	Retry time.Duration
	lock  sync.Mutex
}

func (l *ledger) now() time.Time {
	if l.Now == nil {
		return time.Now()
	}

	return l.Now()
}

func (l *ledger) retry() time.Duration {
	if l.Retry == 0 {
		return Retry
	}

	return l.Retry
}

func (l *ledger) last() (Request, bool) {
	held := Request{}
	if Read(l.Path, &held) != nil || held.Check() != nil {
		return held, false
	}

	return held, true
}

func (l *ledger) claim(self Self, target Target) (bool, error) {
	if err := Allowed(self.Version, target); err != nil {
		return false, err
	}

	if !self.Needs(target) {
		return false, nil
	}

	if held, ok := l.last(); ok && held.SHA256 == target.SHA256 && held.MacReader == target.MacReader &&
		l.now().Sub(held.RequestedAt) < l.retry() {
		return false, nil
	}

	asked := Request{Target: target, From: self.Version, RequestedAt: l.now().UTC()}

	return true, Write(l.Path, asked, l.Mode)
}

func (l *ledger) warnings(self Self, results string) []string {
	held, ok := l.last()
	if !ok || self.Matches(held) || l.now().Sub(held.RequestedAt) < InFlight {
		return nil
	}

	why := ""
	told := Result{}

	if results != "" && Read(filepath.Join(results, ResultFile), &told) == nil && told.SHA256 == held.SHA256 && !told.OK && told.Error != "" {
		why = ": " + told.Error
	}

	again := held.RequestedAt.Add(l.retry()).UTC().Format("15:04 UTC")

	return []string{fmt.Sprintf("xixo link could not update to %s and still runs %s%s. It tries again after %s", held.Version, self.Version, why, again)}
}

type Requester struct {
	Dir     string
	Results string
	Self    Self
	Now     func() time.Time
	Retry   time.Duration
	once    sync.Once
	ledger  *ledger
}

func (r *Requester) book() *ledger {
	r.once.Do(func() {
		r.ledger = &ledger{Path: filepath.Join(r.Dir, RequestFile), Mode: 0o644, Now: r.Now, Retry: r.Retry}
	})

	return r.ledger
}

func (r *Requester) Offer(_ context.Context, target Target) error {
	book := r.book()
	book.lock.Lock()
	defer book.lock.Unlock()

	_, err := book.claim(r.Self, target)

	return err
}

func (r *Requester) Warnings() []string {
	return r.book().warnings(r.Self, r.Results)
}

func (r *Requester) Connected() error {
	return Write(filepath.Join(r.Dir, RunningFile), running(r.Self), 0o644)
}

func running(self Self) Running {
	return Running{Version: self.Version, SHA256: self.SHA256, PID: os.Getpid(), At: time.Now().UTC()}
}

func regular(path string) bool {
	info, err := os.Lstat(path)

	return err == nil && info.Mode().IsRegular()
}

func missing(err error) bool {
	return errors.Is(err, fs.ErrNotExist)
}

func (r *Requester) Mode() string { return "systemd" }
