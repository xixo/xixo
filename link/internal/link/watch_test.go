package link

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/fake"
)

func TestAFileWrittenIntoASharedFolderIsToldToXixo(t *testing.T) {
	folder, _ := shared(t)
	told := make(chan map[string]any, 1)
	greeted := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()
		close(greeted)

		for {
			_, data := socket.Next()
			if data["action"] == "changed" {
				told <- data

				return
			}
		}
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go held.Run(ctx)

	select {
	case <-greeted:
	case <-ctx.Done():
		t.Fatal("xixo link never said hello")
	}

	os.WriteFile(filepath.Join(folder, "notes.txt"), []byte("milk"), 0o644)

	select {
	case data := <-told:
		paths, _ := data["paths"].([]any)
		if data["folder"] != folder || len(paths) != 1 || paths[0] != "notes.txt" {
			t.Fatalf("told %v", data)
		}
	case <-ctx.Done():
		t.Fatal("xixo link told no change")
	}
}

func TestRunStopsWatchingWhenItStopsForGood(t *testing.T) {
	held, _ := linkFor(t, "http://127.0.0.1:1", t.TempDir(), time.Now().Add(time.Hour))
	held.Tokens = refusedForGood()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	started := time.Now()
	held.Run(ctx)

	if waited := time.Since(started); waited > 2*time.Second {
		t.Fatalf("Run took %v to return after it stopped for good", waited)
	}
}

func refusedForGood() masks.TokenSource {
	return masks.TokenSourceFunc(func(context.Context) (*masks.Token, error) {
		return nil, &masks.Error{Code: "invalid_client", Description: "no client is registered with that client_id"}
	})
}
