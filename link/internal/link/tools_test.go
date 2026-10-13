package link

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/fake"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/state"
)

const (
	placeID = "6f7a8b9c-0d1e-4f2a-9b3c-4d5e6f7a8b9c"
	hugeID  = "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d"
)

func TestAMachineOffersNoToolsUntilItsConfigNamesThem(t *testing.T) {
	folder, _ := shared(t)
	finished := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		if tools, ok := hello["tools"].([]any); !ok || len(tools) != 0 {
			t.Errorf("hello offers %v", hello["tools"])
		}

		socket.Next()

		asked := map[string]map[string]any{
			"t-browse":  {"verb": "browse", "args": map[string]any{"folder": folder}},
			"t-find":    {"verb": "find", "args": map[string]any{"query": "small"}},
			"t-peek":    {"verb": "peek", "args": map[string]any{"folder": folder, "path": "small.txt"}},
			"t-place":   {"verb": "place", "args": map[string]any{"folder": folder, "path": "x.txt", "upload": uploadID, "size": 2}},
			"t-examine": {"verb": "examine", "args": map[string]any{"source": map[string]any{"folder": folder, "path": "small.txt"}}},
			"t-model":   {"verb": "model", "args": map[string]any{"kind": "ollama", "messages": []any{map[string]any{"role": "user", "content": "hi"}}}},
		}

		for request, held := range asked {
			socket.Ask(identifier, map[string]any{"request": request, "verb": held["verb"], "args": held["args"]})
		}

		socket.Ask(identifier, map[string]any{"request": "t-list", "verb": "list", "args": map[string]any{"folder": folder}})

		got := gather(socket, len(asked)+1)

		for request := range asked {
			said, _ := got.done[request]["error"].(string)
			if got.done[request]["ok"] != false || !strings.Contains(said, "does not offer the") || !strings.Contains(said, "out of tools") {
				t.Errorf("%s answered %v", request, got.done[request])
			}
		}

		if got.done["t-list"]["ok"] != true {
			t.Errorf("a sync's list was refused: %v", got.done["t-list"])
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished
}

func TestTheToolsAMachineOffersAnswerWithinTheirGates(t *testing.T) {
	folder, _ := shared(t)
	kept := t.TempDir()
	os.MkdirAll(filepath.Join(folder, "notes"), 0o755)
	os.WriteFile(filepath.Join(folder, "notes", "Small Plans.md"), []byte("# plans"), 0o644)
	finished := make(chan struct{})

	var cable *fake.Cable

	cable = fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		tools, _ := hello["tools"].([]any)
		if len(tools) != 5 || tools[0] != "browse" || tools[4] != "extract" {
			t.Errorf("hello offers %v", hello["tools"])
		}

		socket.Next()

		cable.Stage(uploadID, []byte("placed by a tool"))
		cable.Stage(hugeID, make([]byte, MostPlaced+1))

		socket.Ask(identifier, map[string]any{"request": "browse", "verb": "browse", "args": map[string]any{"folder": folder, "limit": 1}})
		socket.Ask(identifier, map[string]any{"request": "find", "verb": "find", "args": map[string]any{"query": "SMALL"}})
		socket.Ask(identifier, map[string]any{"request": "find-empty", "verb": "find", "args": map[string]any{"query": "  "}})
		socket.Ask(identifier, map[string]any{"request": "find-elsewhere", "verb": "find", "args": map[string]any{"query": "a", "folder": "/etc"}})
		socket.Ask(identifier, map[string]any{"request": "peek", "verb": "peek", "args": map[string]any{"folder": folder, "path": "big.bin"}})
		socket.Ask(identifier, map[string]any{"request": "peek-out", "verb": "peek", "args": map[string]any{"folder": folder, "path": "../etc/passwd"}})
		socket.Ask(identifier, map[string]any{"request": placeID, "verb": "place", "args": map[string]any{
			"folder": folder, "path": "placed/by-tool.txt", "upload": uploadID, "size": 16,
		}})
		socket.Ask(identifier, map[string]any{"request": hugeID, "verb": "place", "args": map[string]any{
			"folder": folder, "path": "huge.bin", "upload": hugeID, "size": MostPlaced + 1,
		}})
		socket.Ask(identifier, map[string]any{"request": "place-ro", "verb": "place", "args": map[string]any{
			"folder": kept, "path": "x.txt", "upload": uploadID, "size": 16,
		}})
		socket.Ask(identifier, map[string]any{"request": "examine", "verb": "examine", "args": map[string]any{
			"source": map[string]any{"folder": folder, "path": "small.txt"},
		}})
		socket.Ask(identifier, map[string]any{"request": "examine-upload", "verb": "examine", "args": map[string]any{
			"source": map[string]any{"upload": uploadID}, "size": 16,
		}})
		socket.Ask(identifier, map[string]any{"request": "model", "verb": "model", "args": map[string]any{
			"kind": "ollama", "messages": []any{map[string]any{"role": "user", "content": "hi"}},
		}})

		got := gather(socket, 12)

		browsed, _ := got.done["browse"]["result"].(map[string]any)
		if entries, _ := browsed["entries"].([]any); got.done["browse"]["ok"] != true || len(entries) != 1 || browsed["cursor"] == nil {
			t.Errorf("browse answered %v", got.done["browse"])
		}

		found, _ := got.done["find"]["result"].(map[string]any)
		matches, _ := found["matches"].([]any)
		if got.done["find"]["ok"] != true || len(matches) != 2 || found["complete"] != true {
			t.Errorf("find answered %v", got.done["find"])
		}

		for _, refused := range []string{"find-empty", "find-elsewhere", "peek-out", hugeID, "place-ro", "examine-upload", "model"} {
			if got.done[refused]["ok"] != false {
				t.Errorf("%s was answered: %v", refused, got.done[refused])
			}
		}

		if !strings.Contains(got.done["model"]["error"].(string), "models out of tools") {
			t.Errorf("model answered %v", got.done["model"])
		}

		if got.done["place-ro"]["error"] != folders.ErrReadOnly.Error() || got.done[hugeID]["error"] != ErrPlacedSize.Error() {
			t.Errorf("writes answered %v and %v", got.done["place-ro"], got.done[hugeID])
		}

		peeked, _ := got.done["peek"]["result"].(map[string]any)
		data, _ := base64.StdEncoding.DecodeString(peeked["data"].(string))
		if len(data) != MostPeeked || fmt.Sprint(peeked["total"]) != "614400" {
			t.Errorf("peek sent %d bytes of %v", len(data), peeked["total"])
		}

		if _, ok := got.chunks["peek"]; ok {
			t.Error("peek sent chunks")
		}

		examined, _ := got.done["examine"]["result"].(map[string]any)
		steps, _ := examined["steps"].(map[string]any)
		if _, ok := steps["text"]; !ok || steps["huge"] != nil || examined["files"] != nil {
			t.Errorf("examine answered %v", got.done["examine"])
		}

		if _, ok := got.chunks["examine"]; ok {
			t.Error("examine sent the files it made")
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Folders = folders.New([]folders.Shared{{Path: folder, Writable: true}, {Path: kept}})
	held.Work = t.TempDir()
	held.Tools = []string{state.ToolExtract, state.ToolWrite, state.ToolBrowse, state.ToolRead, state.ToolSearch}
	held.Extract = func(_ context.Context, in extract.Input) (*extract.Output, error) {
		out := &extract.Output{Extractor: "text"}
		out.Set("text", "hi")
		out.Set("huge", strings.Repeat("x", MostStep+1))
		thumb := filepath.Join(in.Work, "thumb.jpg")
		os.WriteFile(thumb, []byte("jpeg"), 0o600)
		out.Attach(extract.File{Role: "thumbnail", Name: "thumb.jpg", MIME: "image/jpeg", Path: thumb})

		return out, nil
	}
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished

	placed, err := os.ReadFile(filepath.Join(folder, "placed", "by-tool.txt"))
	if err != nil || string(placed) != "placed by a tool" {
		t.Fatalf("placed %q %v", placed, err)
	}

	if _, err := os.Stat(filepath.Join(folder, "huge.bin")); err == nil {
		t.Fatal("a file over the cap was written")
	}

	if left, _ := os.ReadDir(held.Work); len(left) != 0 {
		t.Fatalf("the work directory still holds %d entries", len(left))
	}
}

func TestPeekingNeedsTheMachineToLend(t *testing.T) {
	folder, _ := shared(t)
	held := &Link{Folders: folders.New(folders.ReadOnly(folder)), Tools: []string{state.ToolRead}}

	if _, err := held.peek([]byte(`{"folder":"` + folder + `","path":"small.txt"}`)); err != ErrNotLent {
		t.Fatalf("a machine that does not lend peeked: %v", err)
	}

	held.Lend = true

	if _, err := held.peek([]byte(`{"folder":"` + folder + `","path":"small.txt"}`)); err != ErrNotLentByXixo {
		t.Fatalf("a machine xixo did not let lend peeked: %v", err)
	}

	held.Apply(Settings{Lend: true})

	answered, err := held.peek([]byte(`{"folder":"` + folder + `","path":"small.txt","limit":1}`))
	if err != nil || answered.(Peeked).Size != 1 || answered.(Peeked).Total != 2 {
		t.Fatalf("peek answered %+v %v", answered, err)
	}

	if _, err := held.peek([]byte(`{"folder":"` + folder + `","path":"small.txt","offset":5}`)); err == nil {
		t.Fatal("peek took an argument it does not know")
	}
}

func TestFindingStopsAtItsCaps(t *testing.T) {
	folder := t.TempDir()
	for index := range 150 {
		os.WriteFile(filepath.Join(folder, fmt.Sprintf("match-%03d.txt", index)), nil, 0o644)
	}

	held := &Link{Folders: folders.New(folders.ReadOnly(folder))}

	answered, err := held.find(t.Context(), []byte(`{"query":"match","limit":500}`))
	if err != nil {
		t.Fatal(err)
	}

	finds := answered.(*Finds)
	if len(finds.Matches) != MostFound || finds.Complete {
		t.Fatalf("found %d, complete %v", len(finds.Matches), finds.Complete)
	}

	if _, err := held.find(t.Context(), []byte(`{"query":"`+strings.Repeat("a", MostQuery+1)+`"}`)); err != ErrNoQuery {
		t.Fatalf("a long query gave %v", err)
	}
}

func TestXixoNarrowsWhatTheConfigAllowsAndTheConfigStaysTheLimit(t *testing.T) {
	folder, _ := shared(t)
	finished := make(chan struct{})

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		if tools, _ := hello["tools"].([]any); len(tools) != 5 || hello["lend"] != true || hello["extracts_for_others"] != true {
			t.Errorf("hello said %v", hello)
		}

		socket.Next()

		socket.Ask(identifier, map[string]any{"request": "before", "verb": "browse", "args": map[string]any{"folder": folder}})
		before := gather(socket, 1)

		if said, _ := before.done["before"]["error"].(string); !strings.Contains(said, "xixo has not turned on browse") {
			t.Errorf("before settings: %v", before.done["before"])
		}

		socket.Ask(identifier, map[string]any{"settings": map[string]any{"tools": []string{"browse", "write", "models"}, "lend": false, "extracts_for_others": true}})
		socket.Ask(identifier, map[string]any{"request": "browse", "verb": "browse", "args": map[string]any{"folder": folder}})
		socket.Ask(identifier, map[string]any{"request": "read", "verb": "read", "args": map[string]any{"folder": folder, "path": "small.txt"}})
		socket.Ask(identifier, map[string]any{"request": "find", "verb": "find", "args": map[string]any{"query": "small"}})
		socket.Ask(identifier, map[string]any{"request": "model", "verb": "model", "args": map[string]any{"kind": "ollama", "messages": []any{map[string]any{"role": "user", "content": "hi"}}}})

		got := gather(socket, 4)

		if got.done["browse"]["ok"] != true {
			t.Errorf("browse after settings: %v", got.done["browse"])
		}

		if said, _ := got.done["read"]["error"].(string); said != ErrNotLentByXixo.Error() {
			t.Errorf("read: %v", got.done["read"])
		}

		if said, _ := got.done["find"]["error"].(string); !strings.Contains(said, "xixo has not turned on search") {
			t.Errorf("find: %v", got.done["find"])
		}

		if said, _ := got.done["model"]["error"].(string); !strings.Contains(said, "its config leaves models out of tools") {
			t.Errorf("model: %v", got.done["model"])
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	held.Tools = []string{state.ToolBrowse, state.ToolSearch, state.ToolRead, state.ToolWrite, state.ToolExtract}
	held.Apply(Settings{})
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished
}
