package link

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/fake"
)

type trickle struct{}

func (trickle) Read(p []byte) (int, error) {
	time.Sleep(time.Millisecond)

	return copy(p, "x"), nil
}

func TestAHashStopsWhenItsContextEnds(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()

	started := time.Now()

	if _, err := digested(ctx, trickle{}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the hash ended with %v", err)
	}

	if took := time.Since(started); took > time.Second {
		t.Fatalf("the hash went on for %v after its context ended", took)
	}
}

func TestACopyForExtractionStopsWhenItsContextEnds(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
	defer cancel()

	started := time.Now()

	if _, err := copied(ctx, filepath.Join(t.TempDir(), "source"), trickle{}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("the copy ended with %v", err)
	}

	if took := time.Since(started); took > time.Second {
		t.Fatalf("the copy went on for %v after its context ended", took)
	}
}

func TestRunReturnsWithinItsGraceWhileARequestStillRuns(t *testing.T) {
	folder, _ := shared(t)
	running := make(chan struct{})
	stuck := make(chan struct{})
	t.Cleanup(func() { close(stuck) })

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, map[string]any{"request": "stuck", "verb": "extract", "args": map[string]any{
			"source": map[string]any{"folder": folder, "path": "small.txt"}, "mime": "text/plain",
		}})

		for {
			if _, err := socket.Read(); err != nil {
				return
			}
		}
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Unwatched = true
	held.Work = t.TempDir()
	held.Grace = 300 * time.Millisecond
	held.Extract = func(context.Context, extract.Input) (*extract.Output, error) {
		close(running)
		<-stuck

		return &extract.Output{Extractor: "text"}, nil
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	stopped := make(chan error, 1)
	go func() { stopped <- held.Run(ctx) }()

	select {
	case <-running:
	case <-ctx.Done():
		t.Fatal("the request never started")
	}

	asked := time.Now()
	cancel()

	select {
	case err := <-stopped:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run ended with %v", err)
		}

		if took := time.Since(asked); took < held.Grace || took > held.Grace+2*time.Second {
			t.Fatalf("Run took %v to stop with a grace of %v", took, held.Grace)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run waited on a request past its grace")
	}
}

func TestRunStopsAtOnceWhenItsWorkHonorsTheCancel(t *testing.T) {
	folder, _ := shared(t)
	running := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, map[string]any{"request": "long", "verb": "extract", "args": map[string]any{
			"source": map[string]any{"folder": folder, "path": "small.txt"}, "mime": "text/plain",
		}})

		for {
			if _, err := socket.Read(); err != nil {
				return
			}
		}
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Unwatched = true
	held.Work = t.TempDir()
	held.Grace = time.Minute
	held.Extract = func(ctx context.Context, _ extract.Input) (*extract.Output, error) {
		close(running)
		<-ctx.Done()

		return nil, ctx.Err()
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()

	stopped := make(chan error, 1)
	go func() { stopped <- held.Run(ctx) }()

	select {
	case <-running:
	case <-ctx.Done():
		t.Fatal("the request never started")
	}

	cancel()

	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("Run waited for work that had already stopped")
	}
}
