package link

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/fake"
	"github.com/xixo/xixo/link/internal/update"
)

type updates struct {
	lock       sync.Mutex
	offered    []update.Target
	rolledBack []update.Target
	connected  int
	told       chan struct{}
	back       chan struct{}
}

func (u *updates) Mode() string { return "systemd" }

func (u *updates) Offer(_ context.Context, target update.Target) error {
	u.lock.Lock()
	defer u.lock.Unlock()

	u.offered = append(u.offered, target)
	close(u.told)

	return nil
}

func (u *updates) Warnings() []string { return []string{"xixo link could not update"} }

func (u *updates) RollBack(_ context.Context, target update.Target) error {
	u.lock.Lock()
	defer u.lock.Unlock()

	u.rolledBack = append(u.rolledBack, target)
	close(u.back)

	return nil
}

func (u *updates) Report() update.Report {
	return update.Report{
		Result: &update.Result{Version: "0.3.0", SHA256: strings.Repeat("9", 64), Error: "it did not connect"},
		Held:   []update.Held{{Release: strings.Repeat("5", 64), Version: "0.3.0", Serial: 7, Protocol: 1, SHA256: strings.Repeat("9", 64)}},
	}
}

func (u *updates) Connected() error {
	u.lock.Lock()
	defer u.lock.Unlock()

	u.connected++

	return nil
}

func TestXixoTellsTheLinkToUpdate(t *testing.T) {
	folder, _ := shared(t)
	finished := make(chan struct{})
	sha := strings.Repeat("a", 64)
	held := &updates{told: make(chan struct{}), back: make(chan struct{})}

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		if hello["updates"] != "systemd" || hello["sha256"] != strings.Repeat("1", 64) || fmt.Sprint(hello["protocol"]) != "1" || hello["release"] != strings.Repeat("4", 64) || fmt.Sprint(hello["serial"]) != "7" {
			t.Errorf("hello %v", hello)
		}

		if result, _ := hello["update_result"].(map[string]any); result["error"] != "it did not connect" {
			t.Errorf("hello update_result %v", hello["update_result"])
		}

		if releases, _ := hello["releases"].([]any); len(releases) != 1 {
			t.Errorf("hello releases %v", hello["releases"])
		}

		warnings, _ := hello["warnings"].([]any)
		if len(warnings) != 1 || warnings[0] != "xixo link could not update" {
			t.Errorf("hello warnings %v", hello["warnings"])
		}

		socket.Next()
		socket.Ask(identifier, map[string]any{"update": map[string]any{"version": "0.3.0", "sha256": sha, "downgrade": false}})

		select {
		case <-held.told:
		case <-time.After(5 * time.Second):
			t.Error("the update never reached the updater")
		}

		socket.Ask(identifier, map[string]any{"roll_back": map[string]any{"version": "0.2.0", "sha256": strings.Repeat("9", 64)}})

		select {
		case <-held.back:
		case <-time.After(5 * time.Second):
			t.Error("the roll back never reached the updater")
		}

		socket.Close()
	})

	link, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	link.Updates = held
	link.Identity = update.Self{Version: "9.9.9", SHA256: strings.Repeat("1", 64), Protocol: 1, Release: strings.Repeat("4", 64), Serial: 7}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	link.Session(ctx)
	<-finished

	held.lock.Lock()
	defer held.lock.Unlock()

	if len(held.offered) != 1 || held.offered[0].Version != "0.3.0" || held.offered[0].SHA256 != sha {
		t.Fatalf("offered %+v", held.offered)
	}

	if held.connected != 1 {
		t.Fatalf("connected %d times", held.connected)
	}

	if len(held.rolledBack) != 1 || held.rolledBack[0].Version != "0.2.0" {
		t.Fatalf("rolled back %+v", held.rolledBack)
	}
}
