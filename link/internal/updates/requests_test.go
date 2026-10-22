package updates

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"time"
)

func asking(t *testing.T, book *Book, action, channel string, at time.Time) error {
	t.Helper()
	raw, _ := json.Marshal(Ask{Action: action, Channel: channel, At: at, By: "jon"})

	return book.Take(raw)
}

func TestARequestIsTakenOnceAndRemembered(t *testing.T) {
	book, _ := Open(t.TempDir())
	at := time.Now().UTC()

	if err := asking(t, book, Pause, "", at); err != nil || !book.Paused() {
		t.Fatalf("err %v paused %v", err, book.Paused())
	}

	if err := asking(t, book, Resume, "", at); !errors.Is(err, errHandled) || !book.Paused() {
		t.Fatalf("err %v", err)
	}

	reopened, _ := Open(book.Dir)
	if !reopened.Paused() {
		t.Fatal("the pause was not kept")
	}

	if err := asking(t, reopened, Resume, "", at.Add(time.Second)); err != nil || reopened.Paused() {
		t.Fatalf("err %v", err)
	}

	if held := events(t, reopened); held[len(held)-1].Action != Resume || held[len(held)-1].By != "jon" {
		t.Fatalf("events %+v", held)
	}
}

func TestARequestIsCheckedBeforeItIsTaken(t *testing.T) {
	book, _ := Open(t.TempDir())
	now := time.Now().UTC()

	for i, raw := range []string{
		`{"action":"pause","at":"` + now.Format(time.RFC3339Nano) + `","by":"jon","run":"rm -rf /"}`,
		`{"action":"delete","at":"` + now.Add(time.Second).Format(time.RFC3339Nano) + `","by":"jon"}`,
		`{"action":"channel","channel":"nightly","at":"` + now.Add(2*time.Second).Format(time.RFC3339Nano) + `","by":"jon"}`,
		`{"action":"pause","at":"` + now.Add(-48*time.Hour).Format(time.RFC3339Nano) + `","by":"jon"}`,
		`{"action":"pause","at":"` + now.Add(3*time.Second).Format(time.RFC3339Nano) + `","by":""}`,
	} {
		if err := book.Take([]byte(raw)); err == nil {
			t.Fatalf("request %d was taken", i)
		}
	}

	if book.Paused() || book.Channel(Releases) != Releases {
		t.Fatal("a refused request changed something")
	}
}

func TestUpdateNowClearsTheBadMarksAndAChannelChoiceSticks(t *testing.T) {
	book, _ := Open(t.TempDir())
	book.Bad(built)
	now := time.Now().UTC()

	asking(t, book, UpdateNow, "", now)
	asking(t, book, ChooseChannel, Main, now.Add(time.Second))

	if book.IsBad(built) || book.Channel(Releases) != Main {
		t.Fatalf("bad %v channel %s", book.IsBad(built), book.Channel(Releases))
	}

	select {
	case <-book.Asked():
	default:
		t.Fatal("the updater was not woken")
	}
}

func TestARollBackRequestPutsEveryKindBackOnItsPreviousBuild(t *testing.T) {
	watching, gate := watcher(t, Main)
	gate.held[1].Previous = running
	gate.held[1].Current = built
	asking(t, watching.Book, RollBack, "", time.Now().UTC())
	asking(t, watching.Book, Pause, "", time.Now().UTC().Add(time.Second))

	if err := watching.Once(context.Background()); err != nil {
		t.Fatal(err)
	}

	if !slices.Equal(gate.calls, []string{"rollback xixo"}) || !watching.Book.IsBad(built) {
		t.Fatalf("calls %v", gate.calls)
	}
}
