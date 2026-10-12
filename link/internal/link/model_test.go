package link

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/xixo/xixo/link/internal/state"
)

func modelServer(t *testing.T, answer string) (*Link, *atomic.Value) {
	t.Helper()

	asked := &atomic.Value{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/models":
			w.Write([]byte(`{"data":[{"id":"qwen3:8b"},{"id":"other"}]}`))
		case "/v1/chat/completions":
			held := map[string]any{}
			json.NewDecoder(r.Body).Decode(&held)
			asked.Store(held)

			json.NewEncoder(w).Encode(map[string]any{
				"model":   held["model"],
				"choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": answer}, "finish_reason": "stop"}},
			})
		case "/elsewhere":
			http.Redirect(w, r, "http://example.com/", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)

	_, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	number, _ := strconv.Atoi(port)

	return &Link{Tools: []string{state.ToolModels}, ModelPorts: map[string]int{"ollama": number}}, asked
}

func TestAMachineModelAnswersAPrompt(t *testing.T) {
	held, asked := modelServer(t, "four")

	answered, err := held.model(context.Background(), []byte(`{"kind":"ollama","messages":[{"role":"user","content":"two and two"}]}`))
	if err != nil {
		t.Fatal(err)
	}

	said := answered.(Answered)
	if said.Text != "four" || said.Model != "qwen3:8b" || said.Kind != "ollama" || said.Truncated {
		t.Fatalf("answered %+v", said)
	}

	sent := asked.Load().(map[string]any)
	if sent["model"] != "qwen3:8b" || sent["stream"] != false || sent["max_tokens"].(float64) != DefaultTokens {
		t.Fatalf("sent %v", sent)
	}

	if _, err := held.model(context.Background(), []byte(`{"kind":"ollama","model":"other","max_tokens":999999,"messages":[{"role":"user","content":"x"}]}`)); err != nil {
		t.Fatal(err)
	}

	if sent := asked.Load().(map[string]any); sent["model"] != "other" || sent["max_tokens"].(float64) != MostTokens {
		t.Fatalf("sent %v", sent)
	}
}

func TestAMachineModelAnswerIsCapped(t *testing.T) {
	held, _ := modelServer(t, strings.Repeat("é", MostAnswer))

	answered, err := held.model(context.Background(), []byte(`{"kind":"ollama","messages":[{"role":"user","content":"go on"}]}`))
	if err != nil {
		t.Fatal(err)
	}

	said := answered.(Answered)
	if !said.Truncated || len(said.Text) > MostAnswer || !strings.HasPrefix(said.Text, "éé") || strings.ContainsRune(said.Text, '�') {
		t.Fatalf("answered %d bytes, truncated %v", len(said.Text), said.Truncated)
	}
}

func TestAMachineModelRefusesWhatItWasNotMadeFor(t *testing.T) {
	held, _ := modelServer(t, "never")

	cases := map[string]string{
		"an address":      `{"kind":"ollama","url":"http://169.254.169.254/","messages":[{"role":"user","content":"x"}]}`,
		"a host":          `{"kind":"ollama","host":"10.0.0.1","messages":[{"role":"user","content":"x"}]}`,
		"an unknown kind": `{"kind":"vllm","messages":[{"role":"user","content":"x"}]}`,
		"no messages":     `{"kind":"ollama","messages":[]}`,
		"a tool role":     `{"kind":"ollama","messages":[{"role":"tool","content":"x"}]}`,
		"a long prompt":   `{"kind":"ollama","messages":[{"role":"user","content":"` + strings.Repeat("x", MostPrompt+1) + `"}]}`,
	}

	for named, body := range cases {
		if _, err := held.model(context.Background(), []byte(body)); err == nil {
			t.Errorf("%s was answered", named)
		}
	}
}

func TestTheModelClientReachesOnlyLoopback(t *testing.T) {
	held, _ := modelServer(t, "here")
	port := held.ModelPorts["ollama"]
	client := loopback(port)

	response, err := client.Get("http://192.0.2.1:9/v1/models")
	if err != nil {
		t.Fatalf("the client dialled the address it was given: %v", err)
	}
	response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("answered %s", response.Status)
	}

	redirected, err := client.Get("http://127.0.0.1:" + strconv.Itoa(port) + "/elsewhere")
	if err != nil {
		t.Fatal(err)
	}
	redirected.Body.Close()

	if redirected.StatusCode != http.StatusFound {
		t.Fatalf("the client followed a redirect to %s", redirected.Request.URL)
	}
}

func TestAMachineWithoutTheModelServerSaysSo(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()

	held := &Link{Tools: []string{state.ToolModels}, ModelPorts: map[string]int{"ollama": port}}

	_, err = held.model(context.Background(), []byte(`{"kind":"ollama","model":"m","messages":[{"role":"user","content":"x"}]}`))
	if !errors.Is(err, ErrNoModelServer) {
		t.Fatalf("answered %v", err)
	}
}
