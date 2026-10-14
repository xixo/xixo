package link

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/fake"
)

func extraction(folder, request string, within float64) map[string]any {
	asked := map[string]any{"request": request, "verb": "extract", "args": map[string]any{
		"source": map[string]any{"folder": folder, "path": "small.txt"}, "mime": "text/plain",
	}}

	if within > 0 {
		asked["within"] = within
	}

	return asked
}

type started struct {
	lock  sync.Mutex
	names []string
	ended map[string]error
}

func (s *started) add(name string) {
	s.lock.Lock()
	defer s.lock.Unlock()

	s.names = append(s.names, name)
}

func (s *started) end(name string, cause error) {
	s.lock.Lock()
	defer s.lock.Unlock()

	if s.ended == nil {
		s.ended = map[string]error{}
	}

	s.ended[name] = cause
}

func (s *started) seen() []string {
	s.lock.Lock()
	defer s.lock.Unlock()

	return append([]string(nil), s.names...)
}

func (s *started) cause(name string) error {
	s.lock.Lock()
	defer s.lock.Unlock()

	return s.ended[name]
}

func TestACancelStopsTheWorkAndFreesItsSlot(t *testing.T) {
	folder, _ := shared(t)
	running := make(chan struct{})
	ran := &started{}
	finished := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, extraction(folder, "abandoned", 0))
		<-running
		socket.Ask(identifier, map[string]any{"cancel": "abandoned"})
		socket.Ask(identifier, extraction(folder, "next", 0))

		got := gather(socket, 1)
		if _, ok := got.done["next"]; !ok {
			t.Errorf("the request after the cancel was not answered: %v", got.done)
		}

		if _, ok := got.done["abandoned"]; ok {
			t.Error("xixo link answered a request xixo cancelled")
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Heavy = 1
	held.Backlog = 1
	held.Work = t.TempDir()
	held.Extract = func(ctx context.Context, in extract.Input) (*extract.Output, error) {
		if len(ran.seen()) == 0 {
			ran.add("abandoned")
			close(running)
			<-ctx.Done()
			ran.end("abandoned", context.Cause(ctx))

			return nil, ctx.Err()
		}

		ran.add("next")

		return &extract.Output{Extractor: "text"}, nil
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	if cause := ran.cause("abandoned"); !errors.Is(cause, ErrDropped) {
		t.Fatalf("the cancelled work ended with %v", cause)
	}

	if held.requests.held["abandoned"] != nil || len(held.requests.held) != 0 {
		t.Fatalf("finished requests are still held: %v", held.requests.held)
	}
}

func TestAQueuedRequestPastItsDeadlineNeverRuns(t *testing.T) {
	folder, _ := shared(t)
	release := make(chan struct{})
	running := make(chan struct{})
	ran := &started{}
	finished := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, extraction(folder, "first", 0))
		<-running
		socket.Ask(identifier, extraction(folder, "late", 0.1))
		time.Sleep(400 * time.Millisecond)
		close(release)

		got := gather(socket, 1)
		if _, ok := got.done["first"]; !ok {
			t.Errorf("the first request was not answered: %v", got.done)
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Heavy = 1
	held.Work = t.TempDir()
	held.Extract = func(ctx context.Context, in extract.Input) (*extract.Output, error) {
		if len(ran.seen()) == 0 {
			ran.add("first")
			close(running)
			<-release
		} else {
			ran.add("late")
		}

		return &extract.Output{Extractor: "text"}, nil
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	if seen := ran.seen(); len(seen) != 1 {
		t.Fatalf("xixo link ran %v, and the late request should not have run", seen)
	}
}

func TestARunningRequestStopsAtItsDeadline(t *testing.T) {
	folder, _ := shared(t)
	ran := &started{}
	finished := make(chan struct{})
	ended := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, extraction(folder, "slow", 0.1))

		select {
		case <-ended:
		case <-time.After(5 * time.Second):
			t.Error("the work went on past its deadline")
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Work = t.TempDir()
	held.Extract = func(ctx context.Context, in extract.Input) (*extract.Output, error) {
		<-ctx.Done()
		ran.end("slow", context.Cause(ctx))
		close(ended)

		return nil, ctx.Err()
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	if cause := ran.cause("slow"); !errors.Is(cause, ErrLate) {
		t.Fatalf("the work ended with %v", cause)
	}
}

func TestExtractionsLeaveRoomForQuickRequests(t *testing.T) {
	folder, _ := shared(t)
	release := make(chan struct{})
	finished := make(chan struct{})
	busy := make(chan struct{}, 8)

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)
		defer close(release)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		for _, id := range []string{"film-1", "film-2", "film-3"} {
			socket.Ask(identifier, extraction(folder, id, 0))
		}

		<-busy

		socket.Ask(identifier, map[string]any{"request": "listed", "verb": "list", "args": map[string]any{"folder": folder}})
		socket.Ask(identifier, map[string]any{"request": "hashed", "verb": "hash", "args": map[string]any{"folder": folder, "path": "small.txt"}})

		got := gather(socket, 2)
		for _, id := range []string{"listed", "hashed"} {
			if got.done[id]["ok"] != true {
				t.Errorf("%s was not answered while films were extracted: %v", id, got.done[id])
			}
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Parallel = 1
	held.Heavy = 1
	held.Work = t.TempDir()
	held.Extract = func(ctx context.Context, in extract.Input) (*extract.Output, error) {
		busy <- struct{}{}

		select {
		case <-release:
		case <-ctx.Done():
		}

		return &extract.Output{Extractor: "text"}, nil
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished
}

func TestACancelForAnUnknownRequestChangesNothing(t *testing.T) {
	held := &Link{}
	held.requests.drop("never-asked")

	work, done := held.requests.start(t.Context(), &Request{Request: "kept"})
	defer done()

	held.requests.drop("other")

	if work.Err() != nil {
		t.Fatal("a cancel for another request stopped this one")
	}
}
