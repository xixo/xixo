package link

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
	"github.com/xixo/xixo/link/internal/cable"
	"github.com/xixo/xixo/link/internal/digests"
	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/update"
	"github.com/xixo/xixo/link/internal/watch"
)

const (
	Channel   = "LinkChannel"
	ChunkSize = 256 << 10
	Grace     = 5 * time.Second
)

var (
	ErrRevoked = errors.New("this machine was unenrolled, so xixo link stops")
	ErrBusy    = errors.New("xixo link is busy with as much work as it queues; ask again later")
	ErrNotLent = errors.New("this machine does not lend its files' bytes: its config sets lend to false")
	ErrOthers  = errors.New("this machine extracts only its own files: its config sets extracts_for_others to false")
	ErrMoving  = errors.New("the file changed while xixo link read it, so xixo link named no SHA-256; ask again once it settles")
)

const unknownClient = "no client is registered with that client_id"

type Link struct {
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
	Grace    time.Duration
	Parallel int
	Queue    int
	Chunk    int
	Work     string
	Runner   extract.Runner
	Digests  *digests.Cache
	Extract  func(context.Context, extract.Input) (*extract.Output, error)

	Lend              bool
	ExtractsForOthers bool
	Notices           []string
	Tools             []string
	ModelPorts        map[string]int
	Unwatched         bool

	Updates  Updater
	Identity update.Self

	policy   policy
	once     sync.Once
	watching *watch.Watcher
	wire     wire
	recent   recent
	work     sync.WaitGroup
	slots    chan struct{}
	pending  chan struct{}
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
	Offset int64  `json:"offset,omitempty"`
	Length int64  `json:"length,omitempty"`
}

type Hashed struct {
	Digest
	File string `json:"file,omitempty"`
}

type Ranged struct {
	Size   int64 `json:"size"`
	Offset int64 `json:"offset"`
	Total  int64 `json:"total"`
}

type Glimpse struct {
	Size  int64 `json:"size"`
	Total int64 `json:"total"`
}

const mostGlimpsed = 1 << 20

type Size struct {
	Size int64 `json:"size"`
}

func (a *Link) settle() {
	if a.Every == 0 {
		a.Every = time.Minute
	}

	if a.Quiet == 0 {
		a.Quiet = 30 * time.Second
	}

	if a.Drain == 0 {
		a.Drain = 2 * time.Minute
	}

	if a.Grace == 0 {
		a.Grace = Grace
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

func (a *Link) Run(ctx context.Context) error {
	a.settle()
	defer a.finish()

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	if a.Digests != nil {
		a.work.Go(func() { a.keepDigests(ctx) })
	}

	if !a.Unwatched {
		watching, unwatch := context.WithCancel(ctx)
		defer unwatch()

		a.watch(watching)
	}

	var held *session

	drop := func() {
		if held != nil {
			held.end()
			held = nil
		}

		a.wire.swap(nil, nil)
	}
	defer drop()

	wait := time.Second

	for {
		started := time.Now()
		next, err := a.open(ctx)

		if err == nil {
			a.wire.swap(next.conn, next.token)

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

			drop()
		} else if held != nil && held.ended() {
			drop()
		}

		if ctx.Err() != nil {
			return ctx.Err()
		}

		closed := &cable.Disconnected{}
		if errors.As(err, &closed) && closed.Withdrawn() {
			err = fmt.Errorf("%w: xixo has no machine enrolled as this client", ErrRevoked)
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

func (a *Link) finish() {
	done := make(chan struct{})

	go func() {
		a.work.Wait()
		close(done)
	}()

	timer := time.NewTimer(a.Grace)
	defer timer.Stop()

	select {
	case <-done:
	case <-timer.C:
		a.Log.Warn("xixo link stops with work still running, since the work did not end within the grace period", "grace", a.Grace)
	}

	a.saveDigests()
}

func (a *Link) keepDigests(ctx context.Context) {
	ticker := time.NewTicker(a.Every)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.saveDigests()
		}
	}
}

func (a *Link) saveDigests() {
	if a.Digests == nil {
		return
	}

	if err := a.Digests.Save(); err != nil {
		a.Log.Warn("the digests xixo link remembers were not saved, so it hashes those files again after a restart", "error", err)
	}
}

func (a *Link) Session(ctx context.Context) error {
	a.settle()

	held, err := a.open(ctx)
	if err != nil {
		return err
	}

	a.wire.swap(held.conn, held.token)
	held.listen(ctx)

	_, err = held.serve(ctx)

	held.end()
	a.work.Wait()
	a.wire.swap(nil, nil)

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
	*Link
	conn      *cable.Conn
	token     *masks.Token
	listening context.Context
	stop      context.CancelCauseFunc
}

func (a *Link) open(ctx context.Context) (*session, error) {
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

	held := &session{Link: a, conn: conn, token: token}

	if err := held.greet(ctx); err != nil {
		conn.Close()

		return nil, err
	}

	a.Log.Info("connected to xixo", "xixo", a.Xixo)
	a.connected()

	return held, nil
}

func (s *session) greet(ctx context.Context) error {
	hello := s.Machine.Hello(ctx, s.Version, s.Folders.Names())
	hello.Extractors = extract.AvailableTo(s.Runner)
	hello.Warnings = s.warnings()
	hello.Writable = s.Folders.Writable()
	hello.Lend = s.Lend
	hello.ExtractsForOthers = s.ExtractsForOthers

	if err := s.conn.Perform(ctx, "hello", s.greeting(hello)); err != nil {
		return err
	}

	return s.conn.Perform(ctx, "health", s.health())
}

func (s *session) listen(ctx context.Context) {
	s.listening, s.stop = context.WithCancelCause(ctx)

	go func() {
		for {
			read, stop := context.WithTimeout(s.listening, s.Quiet)
			frame, err := s.conn.Receive(read)
			stop()

			if err != nil {
				s.stop(err)

				return
			}

			if frame.Identifier != s.conn.Identifier() || len(frame.Message) == 0 {
				continue
			}

			told := struct {
				Settings *Settings      `json:"settings"`
				Update   *update.Target `json:"update"`
			}{}
			if json.Unmarshal(frame.Message, &told) == nil && told.Settings != nil {
				s.Apply(*told.Settings)

				continue
			}

			if told.Update != nil {
				s.updateTo(ctx, *told.Update)

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

func (s *session) ended() bool {
	return s.listening != nil && s.listening.Err() != nil
}

func (s *session) end() {
	if s.stop != nil {
		s.stop(nil)
	}

	s.conn.Close()
}

func (a *Link) rollover(expiry time.Time) time.Duration {
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
		case <-s.listening.Done():
			return false, context.Cause(s.listening)
		case <-ticker.C:
			if err := s.conn.Perform(ctx, "health", s.health()); err != nil {
				return false, err
			}
		case <-expiring:
			return true, nil
		}
	}
}

func (a *Link) take(ctx context.Context, asked *Request) {
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

func (a *Link) answer(ctx context.Context, asked *Request) {
	switch asked.Verb {
	case "health":
		a.reply(ctx, asked.Request, a.health())
	case "list":
		query := folders.Query{}
		if err := decode(asked.Args, &query); err != nil {
			a.refuse(ctx, asked.Request, err)

			return
		}

		listed, err := a.Folders.List(ctx, query)
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
	case verbRemove:
		a.remove(ctx, asked)
	case verbBrowse, verbFind, verbPeek, verbPlace, verbExamine, verbModel, verbRelay:
		a.tool(ctx, asked)
	default:
		a.refuse(ctx, asked.Request, fmt.Errorf("xixo link does not know the verb %q", asked.Verb))
	}
}

func (a *Link) hash(ctx context.Context, request string, wanted Read) {
	hashed, err := a.hashed(ctx, wanted)
	if err != nil {
		a.refuse(ctx, request, err)

		return
	}

	a.reply(ctx, request, hashed)
}

func (a *Link) hashed(ctx context.Context, wanted Read) (Hashed, error) {
	opened, err := a.Folders.Open(wanted.Folder, wanted.Path)
	if err != nil {
		return Hashed{}, err
	}
	defer opened.Close()

	defer opened.Forget()

	stamp, known := digests.Of(opened.Info)
	if a.Digests == nil || !known {
		digest, err := digested(ctx, opened)

		return Hashed{Digest: digest, File: opened.Identity}, err
	}

	sum, err := a.Digests.Digest(ctx, stamp, func() (string, int64, digests.Stamp, error) {
		digest, err := digested(ctx, opened)
		if err != nil {
			return "", digest.Size, digests.Stamp{}, err
		}

		after, err := opened.Stat()
		if err != nil {
			return "", digest.Size, digests.Stamp{}, err
		}

		held, _ := digests.Of(after)
		if held != stamp || digest.Size != stamp.Size {
			return "", digest.Size, held, ErrMoving
		}

		return digest.SHA256, digest.Size, held, nil
	})
	if err != nil {
		return Hashed{}, err
	}

	return Hashed{Digest: Digest{SHA256: sum, Size: stamp.Size}, File: opened.Identity}, nil
}

func (a *Link) read(ctx context.Context, request string, wanted Read) {
	if err := a.lent(); err != nil {
		a.refuse(ctx, request, err)

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

	ranged := wanted.Offset != 0 || wanted.Length != 0
	if ranged && (wanted.Limit != 0 || wanted.Offset < 0 || wanted.Length < 0 || wanted.Offset > opened.Size) {
		a.refuse(ctx, request, errors.New("a read's offset and length name a part of the file, and come without a limit"))

		return
	}

	var source io.Reader = folders.Halting(ctx, opened)
	if wanted.Limit > 0 {
		source = io.LimitReader(source, wanted.Limit)
	}

	if ranged {
		if _, err := opened.Seek(wanted.Offset, io.SeekStart); err != nil {
			a.refuse(ctx, request, err)

			return
		}

		source = folders.Halting(ctx, opened)
		if wanted.Length > 0 {
			source = io.LimitReader(source, wanted.Length)
		}
	}

	buffer := make([]byte, a.Chunk)
	sent := int64(0)

	for seq := 0; ; seq++ {
		count, err := io.ReadFull(source, buffer)

		if count > 0 {
			chunk := Chunk{Request: request, Seq: seq, Data: base64.StdEncoding.EncodeToString(buffer[:count])}
			if a.wire.perform(ctx, "chunk", chunk) != nil {
				return
			}

			sent += int64(count)
		}

		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			if ranged {
				a.reply(ctx, request, Ranged{Size: sent, Offset: wanted.Offset, Total: opened.Size})
			} else if wanted.Limit > 0 {
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

func (a *Link) reply(ctx context.Context, request string, result any) {
	if err := a.wire.perform(ctx, "reply", Reply{Request: request, OK: true, Result: result}); err != nil {
		a.Log.Warn("a reply did not reach xixo", "request", request, "error", err)
	}
}

func (a *Link) refuse(ctx context.Context, request string, err error) {
	if err := a.wire.perform(ctx, "reply", Reply{Request: request, Error: describe(err)}); err != nil {
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
		errors.Is(err, folders.ErrSkipped), errors.Is(err, folders.ErrNotFile), errors.Is(err, folders.ErrChanged),
		errors.Is(err, ErrMoving):
		return err.Error()
	case errors.Is(err, fs.ErrNotExist):
		return "no such file"
	case errors.Is(err, fs.ErrPermission):
		return "xixo link may not read that"
	default:
		return err.Error()
	}
}
