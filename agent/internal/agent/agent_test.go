package agent

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/agent/internal/extract"
	"github.com/xixo/xixo/agent/internal/fake"
	"github.com/xixo/xixo/agent/internal/folders"
	"github.com/xixo/xixo/agent/internal/machine"
)

const identifier = `{"channel":"AgentChannel"}`

func shared(t *testing.T) (string, []byte) {
	t.Helper()

	folder := t.TempDir()
	big := make([]byte, 600<<10)
	rand.Read(big)

	if err := os.WriteFile(filepath.Join(folder, "big.bin"), big, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(folder, "small.txt"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}

	return folder, big
}

func agentFor(t *testing.T, xixo, folder string, expiry time.Time) (*Agent, *masks.Key) {
	t.Helper()

	dpop, err := masks.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}

	token := &masks.Token{AccessToken: "agent-token", TokenType: "DPoP", Expiry: expiry}

	return &Agent{
		Xixo:    xixo,
		Version: "9.9.9",
		Folders: folders.New(folders.ReadOnly(folder)),
		Machine: &machine.Machine{
			Proc:    t.TempDir(),
			Probe:   func(_ context.Context, port int) bool { return port == 11434 },
			Tailnet: func(context.Context) string { return "100.64.0.7" },
		},
		Tokens: masks.TokenSourceFunc(func(context.Context) (*masks.Token, error) { return token, nil }),
		DPoP:   dpop,
	}, dpop
}

type replies struct {
	chunks map[string][]byte
	seqs   map[string]int
	done   map[string]map[string]any
}

func gather(socket *fake.Socket, want int) *replies {
	held := &replies{chunks: map[string][]byte{}, seqs: map[string]int{}, done: map[string]map[string]any{}}

	for len(held.done) < want {
		command, data := socket.Next()
		if command.Command != "message" || command.Identifier != identifier {
			socket.Fail("unexpected command %+v", command)
		}

		request, _ := data["request"].(string)

		switch data["action"] {
		case "chunk":
			seq, _ := data["seq"].(json.Number).Int64()
			if int(seq) != held.seqs[request] {
				socket.Fail("chunk %d arrived out of order", seq)
			}

			held.seqs[request]++

			decoded, err := base64.StdEncoding.DecodeString(data["data"].(string))
			if err != nil {
				socket.Fail("%v", err)
			}

			if len(decoded) > ChunkSize {
				socket.Fail("a chunk holds %d bytes", len(decoded))
			}

			held.chunks[request] = append(held.chunks[request], decoded...)
		case "reply":
			held.done[request] = data
		case "health":
		default:
			socket.Fail("unexpected action %v", data["action"])
		}
	}

	return held
}

func TestASessionAnswersXixo(t *testing.T) {
	folder, big := shared(t)
	finished := make(chan struct{})

	var cable *fake.Cable
	var dpop *masks.Key
	var held *Agent

	cable = fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		if hello["action"] != "hello" || hello["version"] != "9.9.9" || hello["hostname"] == "" {
			t.Errorf("hello %v", hello)
		}

		folders, _ := hello["folders"].([]any)
		if len(folders) != 1 || folders[0] != folder {
			t.Errorf("hello folders %v", hello["folders"])
		}

		services, _ := hello["services"].([]any)
		if len(services) != 1 || services[0].(map[string]any)["address"] != "100.64.0.7" || services[0].(map[string]any)["kind"] != "ollama" {
			t.Errorf("hello services %v", hello["services"])
		}

		_, health := socket.Next()
		if health["action"] != "health" || health["load"] == nil || health["memory"] == nil || health["disks"] == nil {
			t.Errorf("health %v", health)
		}

		socket.Send(map[string]any{"type": "ping", "message": 1})
		socket.Ask(identifier, map[string]any{"request": "r-list", "verb": "list", "args": map[string]any{"folder": folder}})
		socket.Ask(identifier, map[string]any{"request": "r-read", "verb": "read", "args": map[string]any{"folder": folder, "path": "big.bin"}})
		socket.Ask(identifier, map[string]any{"request": "r-small", "verb": "read", "args": map[string]any{"folder": folder, "path": "small.txt"}})
		socket.Ask(identifier, map[string]any{"request": "r-glimpse", "verb": "read", "args": map[string]any{"folder": folder, "path": "big.bin", "limit": 10}})
		socket.Ask(identifier, map[string]any{"request": "r-greedy", "verb": "read", "args": map[string]any{"folder": folder, "path": "big.bin", "limit": 2 << 20}})
		socket.Ask(identifier, map[string]any{"request": "r-escape", "verb": "read", "args": map[string]any{"folder": folder, "path": "../etc/passwd"}})
		socket.Ask(identifier, map[string]any{"request": "r-elsewhere", "verb": "list", "args": map[string]any{"folder": "/etc"}})
		socket.Ask(identifier, map[string]any{"request": "r-odd", "verb": "delete", "args": map[string]any{}})
		socket.Ask(identifier, map[string]any{"request": "r-health", "verb": "health", "args": map[string]any{}})
		socket.Ask(`{"channel":"Other"}`, map[string]any{"request": "r-other", "verb": "health"})

		got := gather(socket, 9)

		listed := got.done["r-list"]
		entries := listed["result"].(map[string]any)["entries"].([]any)
		if listed["ok"] != true || len(entries) != 2 || entries[0].(map[string]any)["path"] != "big.bin" {
			t.Errorf("list reply %v", listed)
		}

		if got.seqs["r-read"] != 3 || !bytes.Equal(got.chunks["r-read"], big) {
			t.Errorf("read %d chunks holding %d bytes", got.seqs["r-read"], len(got.chunks["r-read"]))
		}

		if size, _ := got.done["r-read"]["result"].(map[string]any)["size"].(json.Number).Int64(); size != int64(len(big)) {
			t.Errorf("read reply %v", got.done["r-read"])
		}

		if string(got.chunks["r-small"]) != "hi" {
			t.Errorf("small read %q", got.chunks["r-small"])
		}

		glimpsed := got.done["r-glimpse"]["result"].(map[string]any)
		size, _ := glimpsed["size"].(json.Number).Int64()
		total, _ := glimpsed["total"].(json.Number).Int64()
		if !bytes.Equal(got.chunks["r-glimpse"], big[:10]) || size != 10 || total != int64(len(big)) {
			t.Errorf("glimpse %d bytes, reply %v", len(got.chunks["r-glimpse"]), glimpsed)
		}

		if _, ok := got.chunks["r-greedy"]; ok {
			t.Errorf("a read past the glimpse limit sent bytes")
		}

		for _, refused := range []string{"r-escape", "r-elsewhere", "r-odd", "r-greedy"} {
			if got.done[refused]["ok"] != false || got.done[refused]["error"] == "" {
				t.Errorf("%s reply %v", refused, got.done[refused])
			}
		}

		if _, ok := got.chunks["r-escape"]; ok {
			t.Errorf("an escaping read sent bytes")
		}

		if got.done["r-health"]["result"].(map[string]any)["disks"] == nil {
			t.Errorf("health reply %v", got.done["r-health"])
		}

		if _, ok := got.done["r-other"]; ok {
			t.Errorf("the agent answered another channel")
		}

		socket.Close()
	})

	held, dpop = agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	if err := held.Session(ctx); err == nil {
		t.Fatal("a closed socket ends the session with an error")
	}

	<-finished

	if len(cable.Proofs()) != 1 {
		t.Fatalf("proofs %v", cable.Proofs())
	}
}

func TestDialRetriesWithTheNonceXixoAsksFor(t *testing.T) {
	folder, _ := shared(t)

	cable := fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()
		socket.Close()
	})
	cable.Nonce = "n-1"

	held, dpop := agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	held.Session(ctx)

	if cable.Refused() != 1 || len(cable.Proofs()) != 1 || cable.Proofs()[0].Nonce != "n-1" {
		t.Fatalf("refused %d proofs %v", cable.Refused(), cable.Proofs())
	}
}

func TestARejectedSubscriptionEndsTheSession(t *testing.T) {
	folder, _ := shared(t)

	cable := fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		socket.Send(map[string]string{"type": "welcome"})
		socket.Next()
		socket.Send(map[string]string{"type": "reject_subscription", "identifier": identifier})
	})

	held, dpop := agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := held.Session(ctx); err == nil || err.Error() != "xixo refused the subscription" {
		t.Fatalf("session ended with %v", err)
	}
}

func TestASessionEndsCleanlyBeforeItsTokenExpires(t *testing.T) {
	folder, _ := shared(t)
	release := make(chan struct{})

	cable := fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()
		<-release
	})
	defer close(release)

	held, dpop := agentFor(t, cable.URL, folder, time.Now().Add(4*time.Second))
	cable.Thumbprint = dpop.Thumbprint()
	held.Quiet = time.Minute

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	started := time.Now()

	if err := held.Session(ctx); err != nil {
		t.Fatalf("an expiring token ends the session cleanly, got %v", err)
	}

	if time.Since(started) > 5*time.Second {
		t.Fatalf("the session lasted %v", time.Since(started))
	}
}

func TestAnExpiringSessionHandsOverBeforeItsWorkIsCut(t *testing.T) {
	folder, _ := shared(t)
	var connections atomic.Int32
	second := make(chan struct{})
	release := make(chan struct{})
	answered := make(chan map[string]any, 1)

	cable := fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		if connections.Add(1) == 2 {
			close(second)

			return
		}

		socket.Ask(identifier, map[string]any{"request": "slow", "verb": "extract", "args": map[string]any{
			"source": map[string]any{"folder": folder, "path": "small.txt"}, "mime": "text/plain",
		}})

		for {
			command, data := socket.Next()
			if command.Command == "message" && data["action"] == "reply" {
				answered <- data

				return
			}
		}
	})

	held, dpop := agentFor(t, cable.URL, folder, time.Now().Add(6*time.Second))
	cable.Thumbprint = dpop.Thumbprint()
	held.Quiet = time.Minute
	held.Work = t.TempDir()
	held.Extract = func(ctx context.Context, _ extract.Input) (*extract.Output, error) {
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}

		return &extract.Output{Extractor: "text"}, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go held.Run(ctx)

	select {
	case <-second:
	case <-ctx.Done():
		t.Fatal("the agent did not open its next connection before the token expired")
	}

	close(release)

	select {
	case reply := <-answered:
		if reply["request"] != "slow" || reply["ok"] != true {
			t.Fatalf("the work in flight was answered with %v", reply)
		}
	case <-ctx.Done():
		t.Fatal("the work in flight was cut off by the handover")
	}
}

func TestRunReconnects(t *testing.T) {
	folder, _ := shared(t)
	var connections atomic.Int32
	again := make(chan struct{})

	cable := fake.NewCable(t, "agent-token", "", func(socket *fake.Socket) {
		socket.Subscribe(identifier)
		socket.Next()
		socket.Next()

		if connections.Add(1) == 2 {
			close(again)
		}

		socket.Close()
	})

	held, dpop := agentFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	go held.Run(ctx)

	select {
	case <-again:
	case <-ctx.Done():
		t.Fatal("the agent did not reconnect")
	}
}

func TestAnUnenrolledMachineStopsForGood(t *testing.T) {
	agent, _ := agentFor(t, "http://127.0.0.1:1", t.TempDir(), time.Now().Add(time.Hour))
	asked := 0
	agent.Tokens = masks.TokenSourceFunc(func(context.Context) (*masks.Token, error) {
		asked++

		return nil, &masks.Error{Code: "invalid_client", Description: "this client is archived"}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err := agent.Run(ctx)
	if !errors.Is(err, ErrRevoked) {
		t.Fatalf("got %v, want ErrRevoked", err)
	}

	if asked != 1 {
		t.Fatalf("asked masks %d times, want once", asked)
	}
}

func TestAnotherRefusalKeepsTrying(t *testing.T) {
	agent, _ := agentFor(t, "http://127.0.0.1:1", t.TempDir(), time.Now().Add(time.Hour))
	agent.Tokens = masks.TokenSourceFunc(func(context.Context) (*masks.Token, error) {
		return nil, &masks.Error{Code: "server_error"}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()

	if err := agent.Run(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("got %v, want the agent still retrying when its context ended", err)
	}
}
