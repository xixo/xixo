package link

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/fake"
	"github.com/xixo/xixo/link/internal/update"
)

type updates struct {
	lock      sync.Mutex
	offered   []update.Target
	connected int
	told      chan struct{}
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
	held := &updates{told: make(chan struct{})}

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		if hello["updates"] != "systemd" || hello["sha256"] != strings.Repeat("1", 64) {
			t.Errorf("hello %v", hello)
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

		socket.Close()
	})

	link, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	link.Updates = held
	link.Identity = update.Self{Version: "9.9.9", SHA256: strings.Repeat("1", 64)}

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
}
