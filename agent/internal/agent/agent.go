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

var ErrRevoked = errors.New("masks no longer knows this machine, so xixo unenrolled it")

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
	Chunk    int
	Work     string
	Runner   extract.Runner
	Extract  func(context.Context, extract.Input) (*extract.Output, error)
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
}

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
}

func (a *Agent) Run(ctx context.Context) error {
	a.settle()

	wait := time.Second

	for {
		started := time.Now()
		err := a.Session(ctx)

		if ctx.Err() != nil {
			return ctx.Err()
		}

		if err == nil {
			wait = time.Second

			continue
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

type session struct {
	*Agent
	conn    *cable.Conn
	token   *masks.Token
	working sync.WaitGroup
	slots   chan struct{}
}

func (a *Agent) Session(ctx context.Context) error {
	a.settle()

	token, err := a.Tokens.Token(ctx)
	if masks.HasCode(err, "invalid_client") {
		return fmt.Errorf("%w: %w", ErrRevoked, err)
	}

	if err != nil {
		return fmt.Errorf("masks gave no token: %w", err)
	}

	conn, err := cable.Dial(ctx, a.Xixo, token, a.DPoP, Channel)
	if err != nil {
		return err
	}

	if err := conn.Subscribe(ctx, 15*time.Second); err != nil {
		conn.Close()

		return err
	}

	a.Log.Info("connected to xixo", "xixo", a.Xixo)

	working, cancel := context.WithCancel(ctx)
	held := &session{Agent: a, conn: conn, token: token, slots: make(chan struct{}, a.Parallel)}

	rolled, err := held.serve(working, token)
	if !rolled {
		cancel()
		held.close()

		return err
	}

	go func() {
		held.finish(time.Until(token.Expiry))
		cancel()
		held.close()
	}()

	return nil
}

func (s *session) close() {
	s.working.Wait()
	s.conn.Close()
}

func (a *Agent) rollover(expiry time.Time) time.Duration {
	left := time.Until(expiry)

	return max(left-min(a.Drain, left/2), time.Second)
}

func (s *session) serve(ctx context.Context, token *masks.Token) (bool, error) {
	listening, cancel := context.WithCancel(ctx)
	defer cancel()

	hello := s.Machine.Hello(ctx, s.Version, s.Folders.Names())
	hello.Extractors = extract.Available()

	if err := s.conn.Perform(ctx, "hello", hello); err != nil {
		return false, err
	}

	if err := s.conn.Perform(ctx, "health", s.Machine.Health(s.Folders.Names())); err != nil {
		return false, err
	}

	frames := make(chan *cable.Frame)
	failed := make(chan error, 1)

	go func() {
		for {
			read, stop := context.WithTimeout(ctx, s.Quiet)
			frame, err := s.conn.Receive(read)
			stop()

			if err != nil {
				failed <- err

				return
			}

			select {
			case frames <- frame:
			case <-listening.Done():
				return
			}
		}
	}()

	ticker := time.NewTicker(s.Every)
	defer ticker.Stop()

	var expiring <-chan time.Time

	if !token.Expiry.IsZero() {
		timer := time.NewTimer(s.rollover(token.Expiry))
		defer timer.Stop()
		expiring = timer.C
	}

	for {
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case err := <-failed:
			cancel()

			return false, err
		case <-ticker.C:
			if err := s.conn.Perform(ctx, "health", s.Machine.Health(s.Folders.Names())); err != nil {
				return false, err
			}
		case <-expiring:
			return true, nil
		case frame := <-frames:
			if frame.Identifier != s.conn.Identifier() || len(frame.Message) == 0 {
				continue
			}

			asked := &Request{}
			if json.Unmarshal(frame.Message, asked) != nil || asked.Request == "" {
				continue
			}

			s.take(ctx, asked)
		}
	}
}

func (s *session) finish(within time.Duration) {
	done := make(chan struct{})

	go func() {
		s.working.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(max(within, 0)):
	}
}

func (s *session) take(ctx context.Context, asked *Request) {
	s.working.Add(1)

	go func() {
		defer s.working.Done()

		select {
		case s.slots <- struct{}{}:
		case <-ctx.Done():
			return
		}
		defer func() { <-s.slots }()

		s.answer(ctx, asked)
	}()
}

func (s *session) answer(ctx context.Context, asked *Request) {
	switch asked.Verb {
	case "health":
		s.reply(ctx, asked.Request, s.Machine.Health(s.Folders.Names()))
	case "list":
		query := folders.Query{}
		if err := decode(asked.Args, &query); err != nil {
			s.refuse(ctx, asked.Request, err)

			return
		}

		listed, err := s.Folders.List(query)
		if err != nil {
			s.refuse(ctx, asked.Request, err)

			return
		}

		s.reply(ctx, asked.Request, listed)
	case "read":
		wanted := Read{}
		if err := decode(asked.Args, &wanted); err != nil {
			s.refuse(ctx, asked.Request, err)

			return
		}

		s.read(ctx, asked.Request, wanted)
	case verbExtract:
		s.extraction(ctx, asked, false)
	case verbDerive:
		s.extraction(ctx, asked, true)
	default:
		s.refuse(ctx, asked.Request, fmt.Errorf("the agent does not know the verb %q", asked.Verb))
	}
}

func (s *session) read(ctx context.Context, request string, wanted Read) {
	opened, err := s.Folders.Open(wanted.Folder, wanted.Path)
	if err != nil {
		s.refuse(ctx, request, err)

		return
	}
	defer opened.Close()

	buffer := make([]byte, s.Chunk)
	sent := int64(0)

	for seq := 0; ; seq++ {
		count, err := io.ReadFull(opened, buffer)

		if count > 0 {
			chunk := Chunk{Request: request, Seq: seq, Data: base64.StdEncoding.EncodeToString(buffer[:count])}
			if s.conn.Perform(ctx, "chunk", chunk) != nil {
				return
			}

			sent += int64(count)
		}

		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			s.reply(ctx, request, Size{Size: sent})

			return
		}

		if err != nil {
			s.refuse(ctx, request, err)

			return
		}
	}
}

func (s *session) reply(ctx context.Context, request string, result any) {
	if err := s.conn.Perform(ctx, "reply", Reply{Request: request, OK: true, Result: result}); err != nil {
		s.Log.Warn("a reply did not reach xixo", "request", request, "error", err)
	}
}

func (s *session) refuse(ctx context.Context, request string, err error) {
	if err := s.conn.Perform(ctx, "reply", Reply{Request: request, Error: describe(err)}); err != nil {
		s.Log.Warn("a refusal did not reach xixo", "request", request, "error", err)
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
	case errors.Is(err, folders.ErrUnshared), errors.Is(err, folders.ErrOutside),
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
