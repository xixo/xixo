package update

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

type Updater struct {
	Xixo     string
	Requests string
	Results  string
	Binary   string
	OS       string
	Arch     string
	Client   *http.Client
	Wait     time.Duration
	Poll     time.Duration
	Log      *slog.Logger
	Vouch    *Vouch
}

func (u *Updater) settle() {
	if u.Wait == 0 {
		u.Wait = Probation
	}

	if u.Poll == 0 {
		u.Poll = 2 * time.Second
	}

	if u.Log == nil {
		u.Log = slog.New(slog.DiscardHandler)
	}
}

func (u *Updater) Apply(ctx context.Context) error {
	u.settle()

	asked := Request{}
	if err := Read(filepath.Join(u.Requests, RequestFile), &asked); err != nil {
		if missing(err) {
			return nil
		}

		return err
	}

	if err := asked.Check(); err != nil {
		return err
	}

	held, err := Digest(u.Binary)
	if err != nil {
		return err
	}

	if held == asked.SHA256 || u.handled(asked) {
		return nil
	}

	err = u.apply(ctx, asked)
	u.record(asked, err)

	return err
}

func (u *Updater) apply(ctx context.Context, asked Request) error {
	u.Log.Info("updating xixo link", "version", asked.Version, "from", asked.From)

	goos, goarch := system(u.OS, u.Arch)

	signed, err := u.Vouch.Release(ctx, asked.Target, goos, goarch)
	if err != nil {
		return err
	}

	fetched, err := Fetch(ctx, u.Client, Address(u.Xixo, BuildFor(goos, goarch)), asked.SHA256, filepath.Dir(u.Binary))
	if err != nil {
		return err
	}
	defer os.Remove(fetched)

	if err := Probe(ctx, fetched, asked.Version); err != nil {
		return err
	}

	swapped := time.Now()

	if err := Swap(fetched, u.Binary); err != nil {
		return err
	}

	if u.connected(ctx, asked, swapped) {
		u.Log.Info("xixo link updated and connected", "version", asked.Version, "serial", signed.Serial)

		if err := u.Vouch.Accept(signed); err != nil {
			u.Log.Warn("xixo link updated, and the serial it accepted could not be kept", "serial", signed.Serial, "error", err)
		}

		return nil
	}

	if err := Restore(u.Binary); err != nil {
		return fmt.Errorf("the new version did not connect, and the one before it could not be put back: %w", err)
	}

	u.Log.Warn("the new xixo link did not connect, so the one before it is back", "version", asked.Version)

	return fmt.Errorf("version %s did not connect to xixo within %s, so xixo link went back to %s", asked.Version, u.Wait, asked.From)
}

func (u *Updater) connected(ctx context.Context, asked Request, since time.Time) bool {
	deadline := time.NewTimer(u.Wait)
	defer deadline.Stop()

	poll := time.NewTicker(u.Poll)
	defer poll.Stop()

	for {
		held := Running{}
		if Read(filepath.Join(u.Requests, RunningFile), &held) == nil &&
			held.SHA256 == asked.SHA256 && !held.At.Before(since.Add(-time.Second)) {
			return true
		}

		select {
		case <-ctx.Done():
			return false
		case <-deadline.C:
			return false
		case <-poll.C:
		}
	}
}

func (u *Updater) handled(asked Request) bool {
	if u.Results == "" {
		return false
	}

	told := Result{}
	if Read(filepath.Join(u.Results, ResultFile), &told) != nil {
		return false
	}

	return told.SHA256 == asked.SHA256 && told.RequestedAt.Equal(asked.RequestedAt)
}

func (u *Updater) record(asked Request, err error) {
	if u.Results == "" {
		return
	}

	told := Result{Version: asked.Version, SHA256: asked.SHA256, RequestedAt: asked.RequestedAt, OK: err == nil, At: time.Now().UTC()}
	if err != nil {
		told.Error = err.Error()
	}

	if werr := Write(filepath.Join(u.Results, ResultFile), told, 0o644); werr != nil && !errors.Is(werr, os.ErrNotExist) {
		u.Log.Warn("the update's result could not be kept", "error", werr)
	}
}
