package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/agent/internal/fake"
	"github.com/xixo/xixo/agent/internal/folders"
)

const (
	writeID    = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
	readOnlyID = "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f7a"
	againID    = "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"
)

func TestAnUploadIsWrittenOnlyIntoAWritableFolder(t *testing.T) {
	folder, _ := shared(t)
	kept := t.TempDir()
	body := []byte("a file placed in default storage")
	finished := make(chan struct{})

	var cable *fake.Cable
	var dpop *masks.Key
	var held *Agent

	cable = fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		writable, _ := hello["writable"].([]any)
		if len(writable) != 1 || writable[0] != folder {
			t.Errorf("hello names %v writable", hello["writable"])
		}

		socket.Next()

		cable.Stage(uploadID, body)
		cable.Stage(badID, body)
		cable.Stage(fileID, body)

		socket.Ask(identifier, map[string]any{"request": writeID, "verb": "write", "args": map[string]any{
			"folder": folder, "path": "uploads/placed.txt", "upload": uploadID, "size": len(body),
		}})
		socket.Ask(identifier, map[string]any{"request": readOnlyID, "verb": "write", "args": map[string]any{
			"folder": kept, "path": "placed.txt", "upload": badID, "size": len(body),
		}})
		socket.Ask(identifier, map[string]any{"request": againID, "verb": "write", "args": map[string]any{
			"folder": folder, "path": "small.txt", "upload": fileID, "size": len(body),
		}})

		got := gather(socket, 3)

		result, _ := got.done[writeID]["result"].(map[string]any)
		if got.done[writeID]["ok"] != true || result["path"] != "uploads/placed.txt" || fmt.Sprint(result["size"]) != fmt.Sprint(len(body)) {
			t.Errorf("write answered %v", got.done[writeID])
		}

		if got.done[readOnlyID]["ok"] != false || got.done[readOnlyID]["error"] != folders.ErrReadOnly.Error() {
			t.Errorf("a read-only folder took a write: %v", got.done[readOnlyID])
		}

		if got.done[againID]["ok"] != false || got.done[againID]["error"] != folders.ErrExists.Error() {
			t.Errorf("an existing file was replaced unasked: %v", got.done[againID])
		}

		socket.Close()
	})

	held, dpop = agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Folders = folders.New([]folders.Shared{{Path: folder, Writable: true}, {Path: kept}})
	held.Work = t.TempDir()
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	placed, err := os.ReadFile(filepath.Join(folder, "uploads", "placed.txt"))
	if err != nil || string(placed) != string(body) {
		t.Fatalf("placed %q %v", placed, err)
	}

	if small, _ := os.ReadFile(filepath.Join(folder, "small.txt")); string(small) != "hi" {
		t.Fatalf("small.txt became %q", small)
	}

	if entries, _ := os.ReadDir(kept); len(entries) != 0 {
		t.Fatalf("the read-only folder holds %d entries", len(entries))
	}

	if left, _ := os.ReadDir(held.Work); len(left) != 0 {
		t.Fatalf("the work directory still holds %d entries", len(left))
	}
}
