package watch

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

var (
	ErrUnsupported = errors.New("this system offers xixo link no way to watch folders")
	errLimit       = errors.New("the system will watch no more folders for xixo link")
)

const (
	Settle  = 2 * time.Second
	Longest = 10 * time.Second
	Batch   = 256
)

type Change struct {
	Folder   string   `json:"folder"`
	Paths    []string `json:"paths"`
	Overflow bool     `json:"overflow,omitempty"`
}

type event struct {
	path    string
	dir     bool
	created bool
}

type backend interface {
	add(dir string) error
	run(ctx context.Context, events chan<- event, overflow chan<- struct{}) error
	close() error
}

type Watcher struct {
	Roots   map[string]string
	Skip    func(name string) bool
	Most    int
	Settle  time.Duration
	Longest time.Duration
	Batch   int
	Log     *slog.Logger

	lock    sync.Mutex
	watched int
	limited map[string]bool
	failed  error
	pending map[string]map[string]bool
	flooded map[string]bool
}

func (w *Watcher) settle() {
	if w.Settle == 0 {
		w.Settle = Settle
	}

	if w.Longest == 0 {
		w.Longest = Longest
	}

	if w.Batch == 0 {
		w.Batch = Batch
	}

	if w.Most == 0 {
		w.Most = most
	}

	if w.Skip == nil {
		w.Skip = func(string) bool { return false }
	}

	if w.Log == nil {
		w.Log = slog.New(slog.DiscardHandler)
	}

	w.lock.Lock()
	w.limited = map[string]bool{}
	w.lock.Unlock()

	w.pending = map[string]map[string]bool{}
	w.flooded = map[string]bool{}
}

func (w *Watcher) Warnings() []string {
	w.lock.Lock()
	defer w.lock.Unlock()

	held := []string{}

	if w.failed != nil {
		held = append(held, fmt.Sprintf("xixo link cannot watch its folders, so changes reach xixo only when it walks them: %v", w.failed))
	}

	for _, folder := range slices.Sorted(func(yield func(string) bool) {
		for folder := range w.limited {
			if !yield(folder) {
				return
			}
		}
	}) {
		held = append(held, fmt.Sprintf("xixo link watches only part of %s, so a change deeper in it reaches xixo when it walks the folder", folder))
	}

	return held
}

func (w *Watcher) Run(ctx context.Context, send func(Change)) error {
	w.settle()

	watcher, err := open()
	if err != nil {
		w.fail(err)

		return err
	}
	defer watcher.close()

	for _, folder := range w.folders() {
		w.descend(watcher, folder, w.Roots[folder])
	}

	events := make(chan event, 1024)
	overflow := make(chan struct{}, 1)
	ran := make(chan error, 1)

	go func() { ran <- watcher.run(ctx, events, overflow) }()

	var quiet, longest <-chan time.Time

	flush := func() {
		quiet, longest = nil, nil

		for _, change := range w.drain() {
			send(change)
		}
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-ran:
			if ctx.Err() == nil && err != nil {
				w.fail(err)
			}

			return err
		case <-overflow:
			for _, folder := range w.folders() {
				w.flooded[folder] = true
			}

			quiet = time.After(w.Settle)
			if longest == nil {
				longest = time.After(w.Longest)
			}
		case seen := <-events:
			if !w.noted(watcher, seen) {
				continue
			}

			quiet = time.After(w.Settle)
			if longest == nil {
				longest = time.After(w.Longest)
			}
		case <-quiet:
			flush()
		case <-longest:
			flush()
		}
	}
}

func (w *Watcher) folders() []string {
	held := make([]string, 0, len(w.Roots))
	for folder := range w.Roots {
		held = append(held, folder)
	}

	slices.Sort(held)

	return held
}

func (w *Watcher) fail(err error) {
	w.lock.Lock()
	defer w.lock.Unlock()

	w.failed = err
}

func (w *Watcher) descend(watcher backend, folder, dir string) {
	_ = filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || !entry.IsDir() {
			return nil
		}

		if path != dir && w.Skip(entry.Name()) {
			return filepath.SkipDir
		}

		w.lock.Lock()
		full := w.watched >= w.Most
		w.lock.Unlock()

		if full {
			w.limit(folder)

			return filepath.SkipAll
		}

		if err := watcher.add(path); err != nil {
			if errors.Is(err, errLimit) {
				w.limit(folder)

				return filepath.SkipAll
			}

			return filepath.SkipDir
		}

		w.lock.Lock()
		w.watched++
		w.lock.Unlock()

		return nil
	})
}

func (w *Watcher) limit(folder string) {
	w.lock.Lock()
	defer w.lock.Unlock()

	if !w.limited[folder] {
		w.Log.Warn("watching stops short of the whole folder", "folder", folder, "watched", w.watched)
	}

	w.limited[folder] = true
}

func (w *Watcher) noted(watcher backend, seen event) bool {
	folder, relative, ok := w.within(seen.path)
	if !ok {
		return false
	}

	if seen.dir && seen.created {
		w.descend(watcher, folder, seen.path)
	}

	held := w.pending[folder]
	if held == nil {
		held = map[string]bool{}
		w.pending[folder] = held
	}

	if len(held) >= w.Batch {
		w.flooded[folder] = true

		return true
	}

	held[relative] = true

	return true
}

func (w *Watcher) within(path string) (string, string, bool) {
	folders := w.folders()
	slices.SortStableFunc(folders, func(a, b string) int { return len(w.Roots[b]) - len(w.Roots[a]) })

	for _, folder := range folders {
		relative, err := filepath.Rel(w.Roots[folder], path)
		if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			continue
		}

		for _, part := range strings.Split(relative, string(filepath.Separator)) {
			if w.Skip(part) {
				return "", "", false
			}
		}

		return folder, filepath.ToSlash(relative), true
	}

	return "", "", false
}

func (w *Watcher) drain() []Change {
	held := []Change{}

	for _, folder := range w.folders() {
		switch {
		case w.flooded[folder]:
			held = append(held, Change{Folder: folder, Paths: []string{}, Overflow: true})
		case len(w.pending[folder]) > 0:
			paths := make([]string, 0, len(w.pending[folder]))
			for path := range w.pending[folder] {
				paths = append(paths, path)
			}

			slices.Sort(paths)
			held = append(held, Change{Folder: folder, Paths: paths})
		}
	}

	w.pending = map[string]map[string]bool{}
	w.flooded = map[string]bool{}

	return held
}
