package digests

import (
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

const (
	Smallest = 1 << 20
	Most     = 100_000
	format   = 1
)

var sha256Hex = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Stamp struct {
	File     string `json:"file"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
	Changed  int64  `json:"changed"`
}

func Of(info fs.FileInfo) (Stamp, bool) {
	return stamped(info)
}

type kept struct {
	Stamp
	SHA256 string `json:"sha256"`
	Used   int64  `json:"used"`
}

type saved struct {
	Format int    `json:"format"`
	Files  []kept `json:"files"`
}

type flight struct {
	done chan struct{}
	sum  string
	err  error
}

type Cache struct {
	Path     string
	Smallest int64
	Most     int

	lock    sync.Mutex
	loaded  bool
	held    map[string]kept
	flights map[Stamp]*flight
	dirty   bool
	read    atomic.Int64
}

func (c *Cache) Hashed() int64 {
	return c.read.Load()
}

func (c *Cache) Known(stamp Stamp) (string, bool) {
	c.lock.Lock()
	defer c.lock.Unlock()

	c.load()

	held, ok := c.held[stamp.File]
	if !ok || held.Stamp != stamp {
		return "", false
	}

	held.Used = time.Now().Unix()
	c.held[stamp.File] = held

	return held.SHA256, true
}

func (c *Cache) Note(stamp Stamp, sum string) {
	if stamp.File == "" || stamp.Size < c.smallest() || !sha256Hex.MatchString(sum) {
		return
	}

	c.lock.Lock()
	defer c.lock.Unlock()

	c.load()
	c.held[stamp.File] = kept{Stamp: stamp, SHA256: sum, Used: time.Now().Unix()}
	c.dirty = true
	c.trim()
}

func (c *Cache) Digest(ctx context.Context, stamp Stamp, hash func() (string, int64, Stamp, error)) (string, error) {
	if sum, ok := c.Known(stamp); ok {
		return sum, nil
	}

	c.lock.Lock()
	if c.flights == nil {
		c.flights = map[Stamp]*flight{}
	}

	if running, ok := c.flights[stamp]; ok {
		c.lock.Unlock()

		select {
		case <-running.done:
			return running.sum, running.err
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}

	running := &flight{done: make(chan struct{})}
	c.flights[stamp] = running
	c.lock.Unlock()

	sum, read, after, err := hash()
	c.read.Add(read)

	if err == nil && after == stamp {
		c.Note(stamp, sum)
	}

	running.sum, running.err = sum, err

	c.lock.Lock()
	delete(c.flights, stamp)
	c.lock.Unlock()
	close(running.done)

	return sum, err
}

func (c *Cache) Save() error {
	c.lock.Lock()
	defer c.lock.Unlock()

	if !c.dirty || c.Path == "" {
		return nil
	}

	files := make([]kept, 0, len(c.held))
	for _, held := range c.held {
		files = append(files, held)
	}

	slices.SortFunc(files, func(a, b kept) int { return int(b.Used - a.Used) })

	raw, err := json.Marshal(saved{Format: format, Files: files})
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(c.Path), 0o700); err != nil {
		return err
	}

	temporary, err := os.CreateTemp(filepath.Dir(c.Path), ".digests-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())

	_, err = temporary.Write(raw)
	if closed := temporary.Close(); err == nil {
		err = closed
	}

	if err != nil {
		return err
	}

	if err := os.Rename(temporary.Name(), c.Path); err != nil {
		return err
	}

	c.dirty = false

	return nil
}

func (c *Cache) smallest() int64 {
	if c.Smallest > 0 {
		return c.Smallest
	}

	return Smallest
}

func (c *Cache) most() int {
	if c.Most > 0 {
		return c.Most
	}

	return Most
}

func (c *Cache) load() {
	if c.loaded {
		return
	}

	c.loaded = true
	c.held = map[string]kept{}

	if c.Path == "" {
		return
	}

	raw, err := os.ReadFile(c.Path)
	if err != nil {
		return
	}

	held := saved{}
	if json.Unmarshal(raw, &held) != nil || held.Format != format {
		return
	}

	for _, file := range held.Files {
		if file.File == "" || !sha256Hex.MatchString(file.SHA256) {
			continue
		}

		c.held[file.File] = file
	}

	c.trim()
}

func (c *Cache) trim() {
	over := len(c.held) - c.most()
	if over <= 0 {
		return
	}

	files := make([]kept, 0, len(c.held))
	for _, held := range c.held {
		files = append(files, held)
	}

	slices.SortFunc(files, func(a, b kept) int { return int(a.Used - b.Used) })

	for _, file := range files[:min(len(files), over+c.most()/10)] {
		delete(c.held, file.File)
	}
}
