package agent

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"math/rand/v2"
	"os"
	"strings"
	"sync"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/agent/internal/cable"
	"github.com/xixo/xixo/agent/internal/extract"
	"github.com/xixo/xixo/agent/internal/folders"
	"github.com/xixo/xixo/agent/internal/machine"
)

const (
	Channel   = "AgentChannel"
	ChunkSize = 256 << 10
)

var (
	ErrRevoked = errors.New("this machine was unenrolled, so the agent stops")
	ErrBusy    = errors.New("the agent is busy with as much work as it queues; ask again later")
	ErrNotLent = errors.New("this machine does not lend its files' bytes: its config sets lend to false")
	ErrOthers  = errors.New("this machine extracts only its own files: its config sets extracts_for_others to false")
)

var Disowned = 10 * time.Minute

const unknownClient = "no client is registered with that client_id"

type Agent struct {
	Xixo     string
	Version  string
	Folders  *folders.Folders
	Machine  *machine.Machine
	Tokens   masks.TokenSource
	DPoP     *masks.Key
	Log      *slog.Logger
	Every    time.Duration
	Quiet    time.Duration
	Drain    time.Duration
	Parallel int
	Queue    int
	Chunk    int
	Work     string
	Runner   extract.Runner
	Extract  func(context.Context, extract.Input) (*extract.Output, error)

	Lend              bool
	ExtractsForOthers bool
	Notices           []string
	Tools             []string
	ModelPorts        map[string]int

	once    sync.Once
	link    link
	recent  recent
	work    sync.WaitGroup
	slots   chan struct{}
	pending chan struct{}
}

type Request struct {
	Request string          `json:"request"`
	Verb    string          `json:"verb"`
	Args    json.RawMessage `json:"args"`
}

type Reply struct {
	Request string `json:"request"`
	OK      bool   `json:"ok"`
	Result  any    `json:"result,omitempty"`
	Error   string `json:"error,omitempty"`
}

type Chunk struct {
	Request string `json:"request"`
	Of      string `json:"of,omitempty"`
	Seq     int    `json:"seq"`
	Data    string `json:"data"`
}

type Read struct {
	Folder string `json:"folder"`
	Path   string `json:"path"`
	Limit  int64  `json:"limit,omitempty"`
}

type Glimpse struct {
	Size  int64 `json:"size"`
	Total int64 `json:"total"`
}

const mostGlimpsed = 1 << 20

type Size struct {
	Size int64 `json:"size"`
}

func (a *Agent) settle() {
	if a.Every == 0 {
		a.Every = time.Minute
	}

	if a.Quiet == 0 {
		a.Quiet = 30 * time.Second
	}

	if a.Drain == 0 {
		a.Drain = 2 * time.Minute
	}

	if a.Parallel == 0 {
		a.Parallel = 4
	}

	if a.Chunk == 0 {
		a.Chunk = ChunkSize
	}

	if a.Log == nil {
		a.Log = slog.New(slog.DiscardHandler)
	}

	if a.Machine == nil {
		a.Machine = machine.New()
	}

	if a.Work == "" {
		a.Work = os.TempDir()
	}

	if a.Runner == nil {
		a.Runner = extract.Limited{}
	}

	if a.Extract == nil {
		a.Extract = extract.Run
	}

	if a.Queue == 0 {
		a.Queue = 64
	}

	a.once.Do(func() {
		a.slots = make(chan struct{}, a.Parallel)
		a.pending = make(chan struct{}, a.Parallel+a.Queue)
	})
}

func (a *Agent) Run(ctx context.Context) error {
	a.settle()
	defer a.work.Wait()

	var held *session

	defer func() {
		if held != nil {
			held.end()
		}

		a.link.swap(nil, nil)
	}()

	wait := time.Second
	var disowned time.Time

	for {
		started := time.Now()
		next, err := a.open(ctx)

		if err == nil {
			disowned = time.Time{}
			a.link.swap(next.conn, next.token)

			if held != nil {
				held.end()
			}

			held = next
			held.listen(ctx)

			var rolled bool
			rolled, err = held.serve(ctx)

			if rolled {
				wait = time.Second

				continue
			}

			held.end()
			held = nil
			a.link.swap(nil, nil)
		} else if held != nil && held.ended() {
			held.end()
			held = nil
			a.link.swap(nil, nil)
		}

		if ctx.Err() != nil {
			return ctx.Err()
		}

		closed := &cable.Disconnected{}
		if errors.As(err, &closed) && closed.Unauthorized() {
			if disowned.IsZero() {
				disowned = started
			} else if time.Since(disowned) >= Disowned {
				err = fmt.Errorf("%w: xixo has refused this machine's client for %s", ErrRevoked, Disowned)
			}
		}

		if errors.Is(err, ErrRevoked) {
			a.Log.Error("stopping for good", "error", err)

			return err
		}

		if time.Since(started) > time.Minute {
			wait = time.Second
		}

		pause := wait/2 + rand.N(wait/2+1)
		a.Log.Warn("the connection to xixo ended", "error", err, "retry", pause.Round(time.Millisecond))

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pause):
		}

		wait = min(wait*2, time.Minute)
	}
}

func (a *Agent) Session(ctx context.Context) error {
	a.settle()

	held, err := a.open(ctx)
	if err != nil {
		return err
	}

	a.link.swap(held.conn, held.token)
	held.listen(ctx)

	_, err = held.serve(ctx)

	held.end()
	a.work.Wait()
	a.link.swap(nil, nil)

	return err
}

func refused(err error) error {
	held := &masks.Error{}

	if errors.As(err, &held) && held.Code == "invalid_client" && strings.Contains(held.Description, unknownClient) {
		return fmt.Errorf("%w: %w", ErrRevoked, err)
	}

	if masks.HasCode(err, "invalid_client") {
		return fmt.Errorf("masks refused this machine's client assertion, which a wrong clock also causes: %w", err)
	}

	return fmt.Errorf("masks gave no token: %w", err)
}

type session struct {
	*Agent
	conn      *cable.Conn
	token     *masks.Token
	listening context.Context
	stop      context.CancelFunc
	failed    chan error
}

func (a *Agent) open(ctx context.Context) (*session, error) {
	token, err := a.Tokens.Token(ctx)
	if err != nil {
		return nil, refused(err)
	}

	conn, err := cable.Dial(ctx, a.Xixo, token, a.DPoP, Channel)
	if err != nil {
		return nil, err
	}

	if err := conn.Subscribe(ctx, 15*time.Second); err != nil {
		conn.Close()

		return nil, err
	}

	held := &session{Agent: a, conn: conn, token: token, failed: make(chan error, 1)}

	if err := held.greet(ctx); err != nil {
		conn.Close()

		return nil, err
	}

	a.Log.Info("connected to xixo", "xixo", a.Xixo)

	return held, nil
}

func (s *session) greet(ctx context.Context) error {
	hello := s.Machine.Hello(ctx, s.Version, s.Folders.Names())
	hello.Extractors = extract.AvailableTo(s.Runner)
	hello.Warnings = s.warnings()
	hello.Writable = s.Folders.Writable()
	hello.Lend = s.Lend
	hello.ExtractsForOthers = s.ExtractsForOthers

	if err := s.conn.Perform(ctx, "hello", greeting{Hello: hello, Tools: s.offered()}); err != nil {
		return err
	}

	return s.conn.Perform(ctx, "health", s.health())
}

func (s *session) listen(ctx context.Context) {
	s.listening, s.stop = context.WithCancel(ctx)

	go func() {
		for {
			read, stop := context.WithTimeout(s.listening, s.Quiet)
			frame, err := s.conn.Receive(read)
			stop()

			if err != nil {
				s.failed <- final(err)

				return
			}

			if frame.Identifier != s.conn.Identifier() || len(frame.Message) == 0 {
				continue
			}

			asked := &Request{}
			if json.Unmarshal(frame.Message, asked) != nil || asked.Request == "" {
				continue
			}

			s.take(ctx, asked)
		}
	}()
}

func final(err error) error {
	disconnected := &cable.Disconnected{}

	if errors.As(err, &disconnected) && disconnected.Unauthorized() {
		return fmt.Errorf("%w: %w", ErrRevoked, err)
	}

	return err
}

func (s *session) ended() bool {
	select {
	case err := <-s.failed:
		s.failed <- err

		return true
	default:
		return false
	}
}

func (s *session) end() {
	if s.stop != nil {
		s.stop()
	}

	s.conn.Close()
}

func (a *Agent) rollover(expiry time.Time) time.Duration {
	left := time.Until(expiry)

	return max(left-min(a.Drain, left/2), time.Second)
}

func (s *session) serve(ctx context.Context) (bool, error) {
	ticker := time.NewTicker(s.Every)
	defer ticker.Stop()

	var expiring <-chan time.Time

	if !s.token.Expiry.IsZero() {
		timer := time.NewTimer(s.rollover(s.token.Expiry))
		defer timer.Stop()
		expiring = timer.C
	}

	for {
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case err := <-s.failed:
			s.failed <- err

			return false, err
		case <-ticker.C:
			if err := s.conn.Perform(ctx, "health", s.health()); err != nil {
				return false, err
			}
		case <-expiring:
			return true, nil
		}
	}
}

func (a *Agent) take(ctx context.Context, asked *Request) {
	if !a.recent.fresh(asked.Request) {
		return
	}

	select {
	case a.pending <- struct{}{}:
	default:
		busy, cancel := context.WithTimeout(ctx, 5*time.Second)
		a.refuse(busy, asked.Request, ErrBusy)
		cancel()

		return
	}

	a.work.Add(1)

	go func() {
		defer a.work.Done()
		defer func() { <-a.pending }()

		select {
		case a.slots <- struct{}{}:
		case <-ctx.Done():
			return
		}
		defer func() { <-a.slots }()

		a.answer(ctx, asked)
	}()
}

func (a *Agent) answer(ctx context.Context, asked *Request) {
	switch asked.Verb {
	case "health":
		a.reply(ctx, asked.Request, a.health())
	case "list":
		query := folders.Query{}
		if err := decode(asked.Args, &query); err != nil {
			a.refuse(ctx, asked.Request, err)

			return
		}

		listed, err := a.Folders.List(query)
		if err != nil {
			a.refuse(ctx, asked.Request, err)

			return
		}

		a.reply(ctx, asked.Request, listed)
	case "read":
		wanted := Read{}
		if err := decode(asked.Args, &wanted); err != nil {
			a.refuse(ctx, asked.Request, err)

			return
		}

		a.read(ctx, asked.Request, wanted)
	case "hash":
		wanted := Read{}
		if err := decode(asked.Args, &wanted); err != nil {
			a.refuse(ctx, asked.Request, err)

			return
		}

		a.hash(ctx, asked.Request, wanted)
	case verbExtract:
		a.extraction(ctx, asked, false)
	case verbDerive:
		a.extraction(ctx, asked, true)
	case verbWrite:
		a.write(ctx, asked)
	case verbBrowse, verbFind, verbPeek, verbPlace, verbExamine, verbModel:
		a.tool(ctx, asked)
	default:
		a.refuse(ctx, asked.Request, fmt.Errorf("the agent does not know the verb %q", asked.Verb))
	}
}

func (a *Agent) hash(ctx context.Context, request string, wanted Read) {
	opened, err := a.Folders.Open(wanted.Folder, wanted.Path)
	if err != nil {
		a.refuse(ctx, request, err)

		return
	}
	defer opened.Close()

	digest, err := digested(opened)
	if err != nil {
		a.refuse(ctx, request, err)

		return
	}

	a.reply(ctx, request, digest)
}

func (a *Agent) read(ctx context.Context, request string, wanted Read) {
	if !a.Lend {
		a.refuse(ctx, request, ErrNotLent)

		return
	}

	opened, err := a.Folders.Open(wanted.Folder, wanted.Path)
	if err != nil {
		a.refuse(ctx, request, err)

		return
	}
	defer opened.Close()

	if wanted.Limit < 0 || wanted.Limit > mostGlimpsed {
		a.refuse(ctx, request, fmt.Errorf("a read is limited to at most %d bytes", mostGlimpsed))

		return
	}

	var source io.Reader = opened
	if wanted.Limit > 0 {
		source = io.LimitReader(opened, wanted.Limit)
	}

	buffer := make([]byte, a.Chunk)
	sent := int64(0)

	for seq := 0; ; seq++ {
		count, err := io.ReadFull(source, buffer)

		if count > 0 {
			chunk := Chunk{Request: request, Seq: seq, Data: base64.StdEncoding.EncodeToString(buffer[:count])}
			if a.link.perform(ctx, "chunk", chunk) != nil {
				return
			}

			sent += int64(count)
		}

		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			if wanted.Limit > 0 {
				a.reply(ctx, request, Glimpse{Size: sent, Total: opened.Size})
			} else {
				a.reply(ctx, request, Size{Size: sent})
			}

			return
		}

		if err != nil {
			a.refuse(ctx, request, err)

			return
		}
	}
}

func (a *Agent) reply(ctx context.Context, request string, result any) {
	if err := a.link.perform(ctx, "reply", Reply{Request: request, OK: true, Result: result}); err != nil {
		a.Log.Warn("a reply did not reach xixo", "request", request, "error", err)
	}
}

func (a *Agent) refuse(ctx context.Context, request string, err error) {
	if err := a.link.perform(ctx, "reply", Reply{Request: request, Error: describe(err)}); err != nil {
		a.Log.Warn("a refusal did not reach xixo", "request", request, "error", err)
	}
}

func decode(raw json.RawMessage, into any) error {
	if len(raw) == 0 {
		return errors.New("the request holds no args")
	}

	if err := json.Unmarshal(raw, into); err != nil {
		return fmt.Errorf("the request's args do not fit: %w", err)
	}

	return nil
}

func describe(err error) string {
	switch {
	case errors.Is(err, folders.ErrUnshared), errors.Is(err, folders.ErrOutside), errors.Is(err, folders.ErrOverlaps),
		errors.Is(err, folders.ErrSkipped), errors.Is(err, folders.ErrNotFile):
		return err.Error()
	case errors.Is(err, fs.ErrNotExist):
		return "no such file"
	case errors.Is(err, fs.ErrPermission):
		return "the agent may not read that"
	default:
		return err.Error()
	}
}
