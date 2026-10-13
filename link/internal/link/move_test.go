package link

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/fake"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/state"
)

func TestAReadSendsOnlyThePartItsOffsetAndLengthName(t *testing.T) {
	folder, big := shared(t)
	finished := make(chan struct{})

	var cable *fake.Cable

	cable = fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		ask := func(request string, args map[string]any) {
			args["folder"] = folder
			args["path"] = "big.bin"
			socket.Ask(identifier, map[string]any{"request": request, "verb": "read", "args": args})
		}

		ask("r-middle", map[string]any{"offset": 300 << 10, "length": 200 << 10})
		ask("r-tail", map[string]any{"offset": 500 << 10})
		ask("r-past", map[string]any{"offset": 700 << 10, "length": 1})
		ask("r-both", map[string]any{"offset": 1, "limit": 10})
		ask("r-backward", map[string]any{"offset": -1, "length": 10})

		got := gather(socket, 5)

		middle := got.done["r-middle"]["result"].(map[string]any)
		size, _ := middle["size"].(json.Number).Int64()
		offset, _ := middle["offset"].(json.Number).Int64()
		total, _ := middle["total"].(json.Number).Int64()

		if !bytes.Equal(got.chunks["r-middle"], big[300<<10:500<<10]) || size != 200<<10 || offset != 300<<10 || total != int64(len(big)) {
			t.Errorf("the middle read sent %d bytes and answered %v", len(got.chunks["r-middle"]), middle)
		}

		if !bytes.Equal(got.chunks["r-tail"], big[500<<10:]) {
			t.Errorf("a read with no length sent %d bytes, not the rest of the file", len(got.chunks["r-tail"]))
		}

		for _, refused := range []string{"r-past", "r-both", "r-backward"} {
			if got.done[refused]["ok"] != false || len(got.chunks[refused]) > 0 {
				t.Errorf("%s answered %v", refused, got.done[refused])
			}
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished
}

func TestAWriteStreamsIntoTheFolderAndKeepsItsTime(t *testing.T) {
	folder := t.TempDir()
	body := make([]byte, 700<<10)
	rand.Read(body)
	at := time.Date(2019, 7, 4, 12, 30, 0, 0, time.UTC)
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
		cable.Stage(badID, body[:10])

		socket.Ask(identifier, map[string]any{"request": writeID, "verb": "write", "args": map[string]any{
			"folder": folder, "path": "raws/2019/DSC_0001.NEF", "upload": uploadID, "size": len(body),
			"modified_at": at.Format(time.RFC3339),
		}})
		socket.Ask(identifier, map[string]any{"request": readOnlyID, "verb": "write", "args": map[string]any{
			"folder": folder, "path": "short.bin", "upload": badID, "size": 11,
		}})

		got := gather(socket, 2)

		if got.done[writeID]["ok"] != true {
			t.Errorf("write answered %v", got.done[writeID])
		}

		if got.done[readOnlyID]["ok"] != false {
			t.Errorf("an upload shorter than its size was written: %v", got.done[readOnlyID])
		}

		socket.Close()
	})

	held, dpop = linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Folders = folders.New([]folders.Shared{{Path: folder, Writable: true}})
	held.Tools = []string{state.ToolWrite}
	held.Work = filepath.Join(t.TempDir(), "missing")
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	written, err := os.ReadFile(filepath.Join(folder, "raws", "2019", "DSC_0001.NEF"))
	if err != nil || !bytes.Equal(written, body) {
		t.Fatalf("the written file holds %d bytes: %v", len(written), err)
	}

	info, err := os.Stat(filepath.Join(folder, "raws", "2019", "DSC_0001.NEF"))
	if err != nil || !info.ModTime().Equal(at) {
		t.Errorf("the written file was modified at %v", info.ModTime())
	}

	if _, err := os.Stat(filepath.Join(folder, "short.bin")); err == nil {
		t.Errorf("a short upload left a file behind")
	}

	left, _ := filepath.Glob(filepath.Join(folder, ".xixo-*.part"))
	if len(left) > 0 {
		t.Errorf("a write left %v behind", left)
	}
}
