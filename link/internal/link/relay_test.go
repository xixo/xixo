package link

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/xixo/xixo/link/internal/parts"
)

func relayArgs(t *testing.T, held map[string]any) json.RawMessage {
	t.Helper()

	raw, err := json.Marshal(held)
	if err != nil {
		t.Fatal(err)
	}

	return raw
}

func TestARelayPassesXixosRequestToTheModelServer(t *testing.T) {
	held, asked := modelServer(t, "four")
	port := held.ModelPorts["ollama"]

	answered, err := held.relay(context.Background(), relayArgs(t, map[string]any{"port": port, "method": "GET", "path": "/v1/models"}))
	if err != nil {
		t.Fatal(err)
	}

	got := answered.(RelayAnswer)
	if got.Status != 200 || got.Body != `{"data":[{"id":"nomic-embed-text:latest"},{"id":"qwen3:8b"},{"id":"other"}]}` {
		t.Fatalf("answered %+v", got)
	}

	body := `{"model":"qwen3:8b","messages":[{"role":"user","content":"two and two"}]}`
	answered, err = held.relay(context.Background(), relayArgs(t, map[string]any{"port": port, "method": "POST", "path": "/v1/chat/completions", "body": body, "within": 30}))
	if err != nil {
		t.Fatal(err)
	}

	if got := answered.(RelayAnswer); got.Status != 200 || got.ContentType == "" {
		t.Fatalf("answered %+v", got)
	}

	if sent := asked.Load().(map[string]any); sent["model"] != "qwen3:8b" {
		t.Fatalf("sent %v", sent)
	}
}

func TestARelayRefusesWhatXixoNeverAsks(t *testing.T) {
	held, _ := modelServer(t, "four")
	port := held.ModelPorts["ollama"]

	cases := []struct {
		args map[string]any
		want error
	}{
		{map[string]any{"port": port + 1, "method": "GET", "path": "/v1/models"}, ErrRelayPort},
		{map[string]any{"port": port, "method": "POST", "path": "/api/pull", "body": "{}"}, ErrRelayPath},
		{map[string]any{"port": port, "method": "POST", "path": "/v1/models"}, ErrRelayPath},
		{map[string]any{"port": port, "method": "GET", "path": "/elsewhere"}, ErrRelayPath},
	}

	for _, asked := range cases {
		if _, err := held.relay(context.Background(), relayArgs(t, asked.args)); !errors.Is(err, asked.want) {
			t.Errorf("relay(%v) = %v, want %v", asked.args, err, asked.want)
		}
	}
}

func TestARelayNamesAServerThatIsDown(t *testing.T) {
	down := &Link{ModelPorts: map[string]int{"ollama": 1}}

	if _, err := down.relay(context.Background(), relayArgs(t, map[string]any{"port": 1, "method": "GET", "path": "/v1/models"})); !errors.Is(err, ErrNoModelServer) {
		t.Fatalf("err %v", err)
	}
}

func TestARelayReachesTheModelServerAPartOfThisMachineRuns(t *testing.T) {
	served, _ := modelServer(t, "four")
	port := served.ModelPorts["ollama"]

	dir := t.TempDir()
	keeper := &parts.Keeper{Dir: dir, Allowed: parts.Known(), Status: func(name string) string { return filepath.Join(dir, name+".status.json") }}
	held := &Link{Parts: keeper}

	if _, err := held.relay(context.Background(), relayArgs(t, map[string]any{"port": port, "method": "GET", "path": "/v1/models"})); !errors.Is(err, ErrRelayPort) {
		t.Fatalf("before the part runs, err %v", err)
	}

	if err := parts.WriteWanted(filepath.Join(dir, parts.Models), parts.Wanted{Version: parts.Recipes[parts.Models].Version, Settings: parts.Settings{Port: port}}); err != nil {
		t.Fatal(err)
	}

	if err := parts.WriteStatus(keeper.Status(parts.Models), parts.Status{Name: parts.Models, State: parts.StateStarting, Port: port, Pulls: []parts.Pull{}}); err != nil {
		t.Fatal(err)
	}

	if _, err := held.relay(context.Background(), relayArgs(t, map[string]any{"port": port, "method": "GET", "path": "/v1/models"})); !errors.Is(err, ErrRelayPort) {
		t.Fatalf("while the part starts, err %v", err)
	}

	if err := parts.WriteStatus(keeper.Status(parts.Models), parts.Status{Name: parts.Models, State: parts.StateRunning, Port: port, Pulls: []parts.Pull{}}); err != nil {
		t.Fatal(err)
	}

	answered, err := held.relay(context.Background(), relayArgs(t, map[string]any{"port": port, "method": "GET", "path": "/v1/models"}))
	if err != nil {
		t.Fatal(err)
	}

	if got := answered.(RelayAnswer); got.Status != 200 {
		t.Fatalf("answered %+v", got)
	}

	if found, ok := held.modelPort("ollama"); !ok || found != port {
		t.Fatalf("modelPort = %d, %v", found, ok)
	}
}
