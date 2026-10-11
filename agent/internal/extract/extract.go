package extract

import (
	"context"
	"errors"
	"io"
	"os/exec"
	"slices"
	"sync"
	"time"
)

type Input struct {
	Path string          `json:"-"`
	Name string          `json:"name"`
	MIME string          `json:"mime"`
	Size int64           `json:"size"`
	Skip map[string]bool `json:"-"`
	Work string          `json:"-"`
	Run  Runner          `json:"-"`
	Set  Settings        `json:"settings"`
}

type Settings struct {
	Thumbnail  int `json:"thumbnail,omitempty"`
	Preview    int `json:"preview,omitempty"`
	Frames     int `json:"frames,omitempty"`
	Share      int `json:"share,omitempty"`
	Transcribe int `json:"transcribe,omitempty"`
}

func (s Settings) Settled() Settings {
	if s.Thumbnail <= 0 {
		s.Thumbnail = 320
	}

	if s.Preview <= 0 {
		s.Preview = 1500
	}

	if s.Frames <= 0 {
		s.Frames = 4
	}

	if s.Share <= 0 || s.Share > 100 {
		s.Share = 100
	}

	if s.Transcribe <= 0 {
		s.Transcribe = 3600
	}

	return s
}

type Step struct {
	Result any    `json:"result"`
	Digest string `json:"digest,omitempty"`
	Error  string `json:"error,omitempty"`
}

type File struct {
	Role string   `json:"role"`
	Name string   `json:"name"`
	MIME string   `json:"mime"`
	Path string   `json:"-"`
	At   *float64 `json:"at,omitempty"`
}

type Output struct {
	Extractor string            `json:"extractor"`
	Steps     map[string]Step   `json:"steps"`
	Dropped   map[string]string `json:"dropped,omitempty"`
	Files     []File            `json:"files,omitempty"`
}

type Extractor interface {
	Name() string
	Handles(mime, name string) bool
	Needs() []string
	Extract(ctx context.Context, in Input) (*Output, error)
}

type Runner interface {
	Run(ctx context.Context, limit time.Duration, program string, args ...string) ([]byte, error)
	RunTo(ctx context.Context, limit time.Duration, stdout io.Writer, program string, args ...string) error
}

var Order = []string{
	"pdf", "image", "media", "doc", "epub", "xlsx", "calendar", "pkpass", "email", "contact", "data", "text", "fallback",
}

var ErrUnhandled = errors.New("no extractor reads that file")

var (
	mu         sync.RWMutex
	registered = map[string]Extractor{}
	lookPath   = exec.LookPath
)

func Register(e Extractor) {
	mu.Lock()
	defer mu.Unlock()

	if !slices.Contains(Order, e.Name()) {
		panic("extract: " + e.Name() + " is not in the extraction order")
	}

	registered[e.Name()] = e
}

func Registered() []Extractor {
	mu.RLock()
	defer mu.RUnlock()

	held := []Extractor{}

	for _, name := range Order {
		if e, ok := registered[name]; ok {
			held = append(held, e)
		}
	}

	return held
}

func For(mime, name string) Extractor {
	for _, e := range Registered() {
		if e.Handles(mime, name) {
			return e
		}
	}

	return nil
}

func Available() []string {
	names := []string{}

	for _, e := range Registered() {
		if usable(e) {
			names = append(names, e.Name())
		}
	}

	return names
}

func usable(e Extractor) bool {
	for _, program := range e.Needs() {
		if _, err := lookPath(program); err != nil {
			return false
		}
	}

	return true
}

func (o *Output) Set(name string, result any) {
	if o.Steps == nil {
		o.Steps = map[string]Step{}
	}

	o.Steps[name] = Step{Result: result}
}

func (o *Output) Fail(name string, err error) {
	if o.Steps == nil {
		o.Steps = map[string]Step{}
	}

	o.Steps[name] = Step{Error: err.Error()}
}

func (o *Output) Drop(what, sentence string) {
	if o.Dropped == nil {
		o.Dropped = map[string]string{}
	}

	o.Dropped[what] = sentence
}

func (o *Output) Attach(f File) {
	o.Files = append(o.Files, f)
}

func (in Input) Skipped(step string) bool {
	return in.Skip[step]
}
