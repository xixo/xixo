package updates

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

const (
	MostEvents = 1000
	MostBad    = 200
)

type Event struct {
	At     time.Time `json:"at"`
	Action string    `json:"action"`
	Kind   string    `json:"kind,omitempty"`
	Digest string    `json:"digest,omitempty"`
	Error  string    `json:"error,omitempty"`
}

type Report struct {
	Channel   string            `json:"channel"`
	Paused    bool              `json:"paused"`
	CheckedAt time.Time         `json:"checked_at"`
	Kinds     []Held            `json:"kinds"`
	Targets   map[string]string `json:"targets"`
}

type Book struct {
	Dir string

	lock   sync.Mutex
	bad    map[string]time.Time
	paused bool
	asked  chan struct{}
}

func Open(dir string) (*Book, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}

	book := &Book{Dir: dir, bad: map[string]time.Time{}, asked: make(chan struct{}, 1)}

	raw, err := os.ReadFile(filepath.Join(dir, "bad.json"))
	if err == nil {
		json.Unmarshal(raw, &book.bad)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}

	return book, nil
}

func (b *Book) Note(event Event) {
	if event.At.IsZero() {
		event.At = time.Now().UTC()
	}

	b.lock.Lock()
	defer b.lock.Unlock()

	path := filepath.Join(b.Dir, "events.jsonl")
	lines := [][]byte{}

	if raw, err := os.ReadFile(path); err == nil {
		scanner := bufio.NewScanner(bytes.NewReader(raw))
		scanner.Buffer(make([]byte, 64<<10), 1<<20)
		for scanner.Scan() {
			lines = append(lines, append([]byte{}, scanner.Bytes()...))
		}
	}

	line, err := json.Marshal(event)
	if err != nil {
		return
	}

	lines = append(lines, line)
	if len(lines) > MostEvents {
		lines = lines[len(lines)-MostEvents:]
	}

	written(path, append(bytes.Join(lines, []byte("\n")), '\n'))
}

func (b *Book) Bad(digest string) {
	b.lock.Lock()
	defer b.lock.Unlock()

	b.bad[digest] = time.Now().UTC()

	if len(b.bad) > MostBad {
		digests := make([]string, 0, len(b.bad))
		for held := range b.bad {
			digests = append(digests, held)
		}
		sort.Slice(digests, func(i, j int) bool { return b.bad[digests[i]].Before(b.bad[digests[j]]) })
		for _, held := range digests[:len(digests)-MostBad] {
			delete(b.bad, held)
		}
	}

	if raw, err := json.Marshal(b.bad); err == nil {
		written(filepath.Join(b.Dir, "bad.json"), raw)
	}
}

func (b *Book) IsBad(digest string) bool {
	b.lock.Lock()
	defer b.lock.Unlock()

	_, held := b.bad[digest]

	return held
}

func (b *Book) Paused() bool {
	b.lock.Lock()
	defer b.lock.Unlock()

	return b.paused
}

func (b *Book) Asked() <-chan struct{} {
	return b.asked
}

func (b *Book) Checked(channel string, kinds []Held, targets map[string]string) {
	report := Report{Channel: channel, Paused: b.Paused(), CheckedAt: time.Now().UTC(), Kinds: kinds, Targets: targets}
	if report.Kinds == nil {
		report.Kinds = []Held{}
	}

	raw, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return
	}

	b.lock.Lock()
	defer b.lock.Unlock()

	written(filepath.Join(b.Dir, "status.json"), raw)
}

func written(path string, raw []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".written-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())

	if _, err := temporary.Write(raw); err != nil {
		temporary.Close()
		return err
	}

	if err := temporary.Chmod(0o644); err != nil {
		temporary.Close()
		return err
	}

	if err := temporary.Close(); err != nil {
		return err
	}

	return os.Rename(temporary.Name(), path)
}
