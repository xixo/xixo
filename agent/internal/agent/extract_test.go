package agent

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/agent/internal/extract"
	_ "github.com/xixo/xixo/agent/internal/extract/plain"
	"github.com/xixo/xixo/agent/internal/fake"
)

const (
	uploadID  = "7f0f6a43-1d55-4a2e-9a39-0e0c6b1d2f10"
	extractID = "2b7a2f8e-6c40-4c39-8f53-5d1e4f6a7b80"
	folderID  = "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f"
	badID     = "0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5a"
	fileID    = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"
)

func TestAnUploadIsExtractedAndItsFilesComeBackFirst(t *testing.T) {
	folder, _ := shared(t)
	if err := os.WriteFile(filepath.Join(folder, "dentist.ics"), []byte("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Cleaning NEEDLE-ICS\r\nDTSTART:20261012T093000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	body := []byte("a plain note holding NEEDLE-UPLOAD")
	finished := make(chan struct{})

	var cable *fake.Cable
	var dpop *masks.Key
	var held *Agent

	cable = fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		extractors, _ := hello["extractors"].([]any)
		if len(extractors) == 0 {
			t.Errorf("hello names no extractors: %v", hello)
		}

		socket.Next()

		cable.Stage(uploadID, body)
		cable.Stage(badID, body)

		socket.Ask(identifier, map[string]any{"request": extractID, "verb": "extract", "args": map[string]any{
			"source": map[string]any{"upload": uploadID}, "size": len(body), "mime": "text/plain", "filename": "note.txt",
		}})
		socket.Ask(identifier, map[string]any{"request": badID, "verb": "extract", "args": map[string]any{
			"source": map[string]any{"upload": badID}, "size": len(body) + 1, "mime": "text/plain", "filename": "short.txt",
		}})
		socket.Ask(identifier, map[string]any{"request": folderID, "verb": "extract", "args": map[string]any{
			"source": map[string]any{"folder": folder, "path": "dentist.ics"}, "mime": "text/calendar",
		}})
		socket.Ask(identifier, map[string]any{"request": fileID, "verb": "extract", "args": map[string]any{
			"source": map[string]any{"upload": uploadID}, "size": len(body), "mime": "text/plain", "filename": "again.txt",
		}})

		got := gather(socket, 4)

		steps := got.done[extractID]["result"].(map[string]any)["steps"].(map[string]any)
		if text := steps["text"].(map[string]any)["result"]; text != string(body) {
			t.Errorf("upload text %v", text)
		}

		calendar := got.done[folderID]["result"].(map[string]any)
		if calendar["extractor"] != "calendar" {
			t.Errorf("folder extraction %v", calendar)
		}

		if !bytes.Contains([]byte(calendar["steps"].(map[string]any)["text"].(map[string]any)["result"].(string)), []byte("NEEDLE-ICS")) {
			t.Errorf("folder extraction %v", calendar)
		}

		if got.done[fileID]["ok"] != false {
			t.Errorf("an upload was extracted twice: %v", got.done[fileID])
		}

		if got.done[badID]["ok"] != false {
			t.Errorf("an upload short of its size was extracted: %v", got.done[badID])
		}

		socket.Close()
	})

	held, dpop = agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Work = t.TempDir()
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	left, _ := os.ReadDir(held.Work)
	if len(left) != 0 {
		t.Fatalf("the work directory still holds %d entries", len(left))
	}
}

func TestFilesStreamBeforeTheReplyUnderTheirOwnIDs(t *testing.T) {
	folder, _ := shared(t)
	picture := bytes.Repeat([]byte{0xAB}, 300<<10)
	finished := make(chan struct{})

	var cable *fake.Cable
	var dpop *masks.Key
	var held *Agent

	cable = fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		socket.Ask(identifier, map[string]any{"request": extractID, "verb": "extract", "args": map[string]any{
			"source": map[string]any{"folder": folder, "path": "small.txt"}, "mime": "image/png", "filename": "small.png",
		}})

		chunks := map[string][]byte{}
		var reply map[string]any

		for reply == nil {
			_, data := socket.Next()

			switch data["action"] {
			case "chunk":
				if data["of"] != extractID {
					t.Errorf("a file chunk names %v", data["of"])
				}

				decoded, _ := base64.StdEncoding.DecodeString(data["data"].(string))
				chunks[data["request"].(string)] = append(chunks[data["request"].(string)], decoded...)
			case "reply":
				reply = data
			}
		}

		files := reply["result"].(map[string]any)["files"].([]any)
		if len(files) != 1 {
			t.Fatalf("files %v", files)
		}

		entry := files[0].(map[string]any)
		id := entry["request_file"].(string)

		if size, _ := entry["size"].(json.Number).Int64(); size != int64(len(picture)) || !bytes.Equal(chunks[id], picture) {
			t.Errorf("file %v arrived as %d bytes", entry, len(chunks[id]))
		}

		if len(id) != 36 || entry["role"] != "thumbnail" {
			t.Errorf("file entry %v", entry)
		}

		socket.Close()
	})

	held, dpop = agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Work = t.TempDir()
	held.Extract = func(_ context.Context, in extract.Input) (*extract.Output, error) {
		made := filepath.Join(in.Work, "thumbnail.jpg")
		if err := os.WriteFile(made, picture, 0o600); err != nil {
			return nil, err
		}

		out := &extract.Output{Extractor: "image"}
		out.Attach(extract.File{Role: "thumbnail", Name: "thumbnail.jpg", MIME: "image/jpeg", Path: made})

		return out, nil
	}
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished
}
