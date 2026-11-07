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
	labels  map[string]map[string]string
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

func (r *fakeRegistry) Labels(_ context.Context, image, digest string) (map[string]string, error) {
	if labels, found := r.labels[image+"@"+digest]; found {
		return labels, nil
	}

	return nil, errors.New("no such image")
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
		labels:  map[string]map[string]string{},
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

func reported(t *testing.T, book *Book) Report {
	t.Helper()
	report := Report{}
	raw, _ := os.ReadFile(filepath.Join(book.Dir, "status.json"))
	if err := json.Unmarshal(raw, &report); err != nil {
		t.Fatal(err)
	}

	return report
}

func TestTheStatusSaysWhenCIHasSignedANewerUpdaterThanTheOneRunning(t *testing.T) {
	watching, _ := watcher(t, Main)
	watching.Version = "0.6.1+ca2c19b"
	held := watching.Registry.(*fakeRegistry)
	held.digests["ghcr.io/xixo/xixo-updater:main"] = built
	held.bundles["ghcr.io/xixo/xixo-updater@"+built] = [][]byte{bundle(t)}
	held.labels["ghcr.io/xixo/xixo-updater@"+built] = map[string]string{Revision: "deadbeefcafe0123456789", Created: "2026-11-07T20:00:00Z"}

	if err := watching.Once(context.Background()); err != nil {
		t.Fatal(err)
	}

	updater := reported(t, watching.Book).Updater
	if updater == nil || updater.Version != "0.6.1+ca2c19b" || updater.Newest != "deadbee" || updater.NewestDigest != built ||
		updater.NewestCreated != "2026-11-07T20:00:00Z" || !updater.Behind {
		t.Fatalf("updater %+v", updater)
	}

	watching.Version = "0.6.1+deadbee"
	if err := watching.Once(context.Background()); err != nil {
		t.Fatal(err)
	}

	if updater = reported(t, watching.Book).Updater; updater == nil || updater.Behind || updater.Newest != "deadbee" {
		t.Fatalf("the running commit counts as behind: %+v", updater)
	}
}

func TestAnUpdaterBuildWithoutAnAttestationIsNotOffered(t *testing.T) {
	watching, _ := watcher(t, Main)
	watching.Version = "0.6.1+ca2c19b"
	held := watching.Registry.(*fakeRegistry)
	held.digests["ghcr.io/xixo/xixo-updater:main"] = running
	held.labels["ghcr.io/xixo/xixo-updater@"+running] = map[string]string{Revision: "deadbeefcafe0123456789"}

	if err := watching.Once(context.Background()); err != nil {
		t.Fatal(err)
	}

	if updater := reported(t, watching.Book).Updater; updater == nil || updater.Version != "0.6.1+ca2c19b" || updater.Newest != "" || updater.Behind {
		t.Fatalf("updater %+v", updater)
	}
}

func TestOnReleasesTheNewestUpdaterIsTheHighestRelease(t *testing.T) {
	for _, held := range []struct {
		candidate, than string
		newer           bool
	}{
		{"0.10.0", "0.9.9", true},
		{"0.6.2", "0.6.1", true},
		{"0.6.1", "0.6.1", false},
		{"0.6.0", "0.6.1", false},
		{"main", "0.6.1", false},
		{"0.7.0", "dev", false},
	} {
		if Newer(held.candidate, held.than) != held.newer {
			t.Errorf("Newer(%q, %q) is not %v", held.candidate, held.than, held.newer)
		}
	}
}
