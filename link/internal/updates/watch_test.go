package updates

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

type fakeRegistry struct {
	digests map[string]string
	tags    map[string][]string
	bundles map[string][][]byte
}

func (r *fakeRegistry) Digest(_ context.Context, image, tag string) (string, error) {
	if digest, found := r.digests[image+":"+tag]; found {
		return digest, nil
	}

	return "", errors.New("no such tag")
}

func (r *fakeRegistry) Tags(_ context.Context, image string) ([]string, error) {
	return r.tags[image], nil
}

func (r *fakeRegistry) Bundles(_ context.Context, image, digest string) ([][]byte, error) {
	return r.bundles[image+"@"+digest], nil
}

type fakeGate struct {
	held      []Held
	calls     []string
	swapFails bool
	unhealthy bool
}

func (g *fakeGate) Status(context.Context) ([]Held, error) {
	held := []Held{}
	for _, status := range g.held {
		copied := status
		copied.Containers = []Running{{Name: status.Name + "-1", State: "running", Health: "healthy"}}
		if g.unhealthy && status.Current == built {
			copied.Containers[0].Health = "unhealthy"
		}
		held = append(held, copied)
	}

	return held, nil
}

func (g *fakeGate) Pull(_ context.Context, request Request) error {
	g.calls = append(g.calls, "pull "+request.Kind)
	return nil
}

func (g *fakeGate) Swap(_ context.Context, request Request) error {
	g.calls = append(g.calls, "swap "+request.Kind)
	if g.swapFails {
		return errors.New("it did not come up")
	}

	for i := range g.held {
		if g.held[i].Name == request.Kind {
			g.held[i].Previous, g.held[i].Current = g.held[i].Current, request.Digest
		}
	}

	return nil
}

func (g *fakeGate) Rollback(_ context.Context, kind string) error {
	g.calls = append(g.calls, "rollback "+kind)
	for i := range g.held {
		if g.held[i].Name == kind {
			g.held[i].Current = g.held[i].Previous
		}
	}

	return nil
}

func watcher(t *testing.T, channel string) (*Watcher, *fakeGate) {
	t.Helper()
	book, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	gate := &fakeGate{held: []Held{{Name: "masks", Current: running}, {Name: "xixo", Current: running}}}
	registry := &fakeRegistry{
		digests: map[string]string{"ghcr.io/xixo/xixo:main": built, "ghcr.io/masksrb/masks:main": running, "ghcr.io/xixo/xixo:0.2.0": built},
		tags:    map[string][]string{"ghcr.io/xixo/xixo": {"main", "0.1.9", "0.2.0", "0.10.0-rc", "latest"}},
		bundles: map[string][][]byte{"ghcr.io/xixo/xixo@" + built: {bundle(t)}},
	}

	return &Watcher{Gate: gate, Registry: registry, Checker: trusted(t), Channel: channel, Book: book, Watching: 50 * time.Millisecond, Polled: 10 * time.Millisecond}, gate
}

func events(t *testing.T, book *Book) []Event {
	t.Helper()
	raw, _ := os.ReadFile(filepath.Join(book.Dir, "events.jsonl"))
	held := []Event{}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		event := Event{}
		if json.Unmarshal([]byte(line), &event) == nil {
			held = append(held, event)
		}
	}

	return held
}

func TestOnMainTheUpdaterPullsAndSwapsTheNewBuildAndWritesItsStatus(t *testing.T) {
	watching, gate := watcher(t, Main)

	if err := watching.Once(context.Background()); err != nil {
		t.Fatal(err)
	}

	if !slices.Equal(gate.calls, []string{"pull xixo", "swap xixo"}) {
		t.Fatalf("calls %v", gate.calls)
	}

	report := Report{}
	raw, _ := os.ReadFile(filepath.Join(watching.Book.Dir, "status.json"))
	if err := json.Unmarshal(raw, &report); err != nil || report.Channel != Main || report.Targets["xixo"] != built || report.Kinds[1].Current != built {
		t.Fatalf("report %+v err %v", report, err)
	}

	gate.calls = nil
	watching.Once(context.Background())
	if len(gate.calls) != 0 {
		t.Fatalf("a build already running was swapped again: %v", gate.calls)
	}
}

func TestTheReleasesChannelWantsAnAttestationFromTheReleaseWorkflow(t *testing.T) {
	watching, gate := watcher(t, Releases)

	watching.Once(context.Background())

	if len(gate.calls) != 0 {
		t.Fatalf("calls %v", gate.calls)
	}

	if !watching.Book.IsBad(built) {
		t.Fatal("the refused build was not marked")
	}

	refused := events(t, watching.Book)
	if !slices.ContainsFunc(refused, func(event Event) bool {
		return event.Action == "refuse" && event.Kind == "xixo" && strings.Contains(event.Error, "release.yml")
	}) {
		t.Fatalf("events %+v", refused)
	}
}

func TestAFailedSwapMarksTheBuildBadAndItIsNotTriedAgain(t *testing.T) {
	watching, gate := watcher(t, Main)
	gate.swapFails = true

	watching.Once(context.Background())
	if !watching.Book.IsBad(built) {
		t.Fatal("not marked bad")
	}

	gate.calls = nil
	watching.Once(context.Background())
	if len(gate.calls) != 0 {
		t.Fatalf("calls %v", gate.calls)
	}
}

func TestAServiceThatTurnsUnhealthyWhileWatchedRollsBack(t *testing.T) {
	watching, gate := watcher(t, Main)
	gate.unhealthy = true

	watching.Once(context.Background())

	if !slices.Equal(gate.calls, []string{"pull xixo", "swap xixo", "rollback xixo"}) {
		t.Fatalf("calls %v", gate.calls)
	}

	if !watching.Book.IsBad(built) || gate.held[1].Current != running {
		t.Fatalf("held %+v", gate.held)
	}
}

func TestTheHighestReleaseIsANumberedOne(t *testing.T) {
	if got := Highest([]string{"main", "0.9.0", "0.10.0", "0.2.11", "1.0.0-rc.1", "latest", "0.10"}); got != "0.10.0" {
		t.Fatalf("got %q", got)
	}

	if got := Highest([]string{"main"}); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestTheEventLogKeepsTheLastThousandLines(t *testing.T) {
	book, _ := Open(t.TempDir())
	for i := 0; i < MostEvents+5; i++ {
		book.Note(Event{Action: "check"})
	}

	if held := events(t, book); len(held) != MostEvents {
		t.Fatalf("%d events", len(held))
	}
}
