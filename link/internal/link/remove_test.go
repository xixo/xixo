package link

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/fake"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/state"
)

const (
	datedID     = "6f7a8b9c-0d1e-4f2a-9b3c-4d5e6f7a8b9c"
	removeID    = "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d"
	mismatchID  = "8b9c0d1e-2f3a-4b4c-9d5e-6f7a8b9c0d1e"
	readOnlyRID = "9c0d1e2f-3a4b-4c5d-8e6f-7a8b9c0d1e2f"
	unknownID   = "0d1e2f3a-4b5c-4d6e-9f7a-8b9c0d1e2f3a"
)

func digestOf(body []byte) string {
	held := sha256.Sum256(body)

	return hex.EncodeToString(held[:])
}

func TestAMoveWritesWithTheSourceTimeAndRemovesOnlyMatchingBytes(t *testing.T) {
	folder, _ := shared(t)
	kept := t.TempDir()
	os.WriteFile(filepath.Join(kept, "keep.txt"), []byte("keep"), 0o644)
	os.MkdirAll(filepath.Join(folder, "trip"), 0o755)
	os.WriteFile(filepath.Join(folder, "trip", "gone.nef"), []byte("raw bytes"), 0o644)

	body := []byte("a photograph from 2019")
	modified := time.Date(2019, 7, 4, 12, 30, 15, 0, time.UTC)
	finished := make(chan struct{})

	var cable *fake.Cable
	var dpop *masks.Key
	var held *Link

	cable = fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		cable.Stage(uploadID, body)

		socket.Ask(identifier, map[string]any{"request": datedID, "verb": "write", "args": map[string]any{
			"folder": folder, "path": "moved/photo.jpg", "upload": uploadID, "size": len(body),
			"modified_at": modified.Format(time.RFC3339Nano),
		}})
		socket.Ask(identifier, map[string]any{"request": mismatchID, "verb": "remove", "args": map[string]any{
			"folder": folder, "path": "small.txt", "sha256": digestOf([]byte("not hi")), "size": 2,
		}})
		socket.Ask(identifier, map[string]any{"request": removeID, "verb": "remove", "args": map[string]any{
			"folder": folder, "path": "trip/gone.nef", "sha256": digestOf([]byte("raw bytes")), "size": 9, "prune": true,
		}})
		socket.Ask(identifier, map[string]any{"request": readOnlyRID, "verb": "remove", "args": map[string]any{
			"folder": kept, "path": "keep.txt", "sha256": digestOf([]byte("keep")), "size": 4,
		}})
		socket.Ask(identifier, map[string]any{"request": unknownID, "verb": "remove", "args": map[string]any{
			"folder": folder, "path": "small.txt", "sha256": digestOf([]byte("hi")), "size": 2, "force": true,
		}})

		got := gather(socket, 5)

		written, _ := got.done[datedID]["result"].(map[string]any)
		if got.done[datedID]["ok"] != true || written["modified_at"] != modified.Format(time.RFC3339Nano) {
			t.Errorf("write answered %v", got.done[datedID])
		}

		if got.done[mismatchID]["ok"] != false || got.done[mismatchID]["error"] != folders.ErrChanged.Error() {
			t.Errorf("other bytes were removed: %v", got.done[mismatchID])
		}

		removed, _ := got.done[removeID]["result"].(map[string]any)
		pruned, _ := removed["pruned"].([]any)
		if got.done[removeID]["ok"] != true || removed["path"] != "trip/gone.nef" || len(pruned) != 1 || pruned[0] != "trip" {
			t.Errorf("remove answered %v", got.done[removeID])
		}

		if got.done[readOnlyRID]["ok"] != false || got.done[readOnlyRID]["error"] != folders.ErrReadOnly.Error() {
			t.Errorf("a read-only folder lost a file: %v", got.done[readOnlyRID])
		}

		if got.done[unknownID]["ok"] != false {
			t.Errorf("a removal with an argument it does not know went ahead: %v", got.done[unknownID])
		}

		socket.Close()
	})

	held, dpop = linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Folders = folders.New([]folders.Shared{{Path: folder, Writable: true}, {Path: kept}})
	held.Tools = []string{state.ToolWrite}
	held.Work = t.TempDir()
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	info, err := os.Stat(filepath.Join(folder, "moved", "photo.jpg"))
	if err != nil || !info.ModTime().Equal(modified) {
		t.Fatalf("the written file's time is %v %v", info, err)
	}

	if small, _ := os.ReadFile(filepath.Join(folder, "small.txt")); string(small) != "hi" {
		t.Fatalf("small.txt became %q", small)
	}

	if _, err := os.Stat(filepath.Join(folder, "trip")); !os.IsNotExist(err) {
		t.Fatalf("the emptied folder is still there: %v", err)
	}

	if _, err := os.Stat(filepath.Join(kept, "keep.txt")); err != nil {
		t.Fatalf("the read-only folder lost its file: %v", err)
	}
}

func TestRemoveNeedsTheWriteTool(t *testing.T) {
	folder, _ := shared(t)
	finished := make(chan struct{})

	var cable *fake.Cable
	var dpop *masks.Key
	var held *Link

	cable = fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, map[string]any{"request": removeID, "verb": "remove", "args": map[string]any{
			"folder": folder, "path": "small.txt", "sha256": digestOf([]byte("hi")), "size": 2,
		}})

		got := gather(socket, 1)
		if got.done[removeID]["ok"] != false || got.done[removeID]["error"] != (&NotOffered{Tool: state.ToolWrite}).Error() {
			t.Errorf("remove without the write tool answered %v", got.done[removeID])
		}

		socket.Close()
	})

	held, dpop = linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Folders = folders.New([]folders.Shared{{Path: folder, Writable: true}})
	held.Tools = []string{state.ToolBrowse}
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	if small, _ := os.ReadFile(filepath.Join(folder, "small.txt")); string(small) != "hi" {
		t.Fatalf("small.txt became %q", small)
	}
}
