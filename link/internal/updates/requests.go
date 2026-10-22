package updates

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
	"unicode/utf8"
)

const (
	UpdateNow     = "update_now"
	Pause         = "pause"
	Resume        = "resume"
	RollBack      = "roll_back"
	ChooseChannel = "channel"
	MostAsk       = 4096
	MostBy        = 200
	AskedEvery    = 5 * time.Second
	OldestAsk     = 24 * time.Hour
)

type Ask struct {
	Action  string    `json:"action"`
	Channel string    `json:"channel,omitempty"`
	At      time.Time `json:"at"`
	By      string    `json:"by"`
}

func (b *Book) Requests(ctx context.Context, path string, every time.Duration) {
	for {
		if raw, err := asked(path); err == nil {
			if err := b.Take(raw); err != nil && !errors.Is(err, errHandled) {
				b.Note(Event{Action: "request", Error: err.Error()})
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(or(every, AskedEvery)):
		}
	}
}

func asked(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	return io.ReadAll(io.LimitReader(file, MostAsk+1))
}

var errHandled = errors.New("the request was handled already")

func (b *Book) Take(raw []byte) error {
	event, err := b.taken(raw)
	if err != nil {
		return err
	}

	b.Note(event)
	b.ask()

	return nil
}

func (b *Book) taken(raw []byte) (Event, error) {
	if len(raw) > MostAsk {
		return Event{}, fmt.Errorf("the request is larger than %d bytes", MostAsk)
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()

	held := Ask{}
	if err := decoder.Decode(&held); err != nil {
		return Event{}, fmt.Errorf("the request is not one the updater takes: %w", err)
	}

	b.lock.Lock()
	defer b.lock.Unlock()

	if !held.At.After(b.settings.Handled) {
		return Event{}, errHandled
	}

	b.settings.Handled = held.At
	b.saved()

	if held.At.Before(time.Now().Add(-OldestAsk)) || held.At.After(time.Now().Add(time.Minute)) {
		return Event{}, fmt.Errorf("the request is dated %s, outside the last day", held.At.Format(time.RFC3339))
	}

	if !utf8.ValidString(held.By) || held.By == "" || len(held.By) > MostBy {
		return Event{}, errors.New("the request names no one who made it")
	}

	switch held.Action {
	case UpdateNow:
		clear(b.bad)
		if raw, err := json.Marshal(b.bad); err == nil {
			written(filepath.Join(b.Dir, "bad.json"), raw)
		}
	case Pause:
		b.settings.Paused = true
	case Resume:
		b.settings.Paused = false
	case RollBack:
		b.settings.RollBack = true
	case ChooseChannel:
		if held.Channel != Main && held.Channel != Releases {
			return Event{}, fmt.Errorf("%q is not a channel: name main or releases", held.Channel)
		}
		b.settings.Channel = held.Channel
	default:
		return Event{}, fmt.Errorf("%q is not something the updater does", held.Action)
	}

	b.saved()

	return Event{Action: held.Action, By: held.By, Channel: held.Channel}, nil
}
