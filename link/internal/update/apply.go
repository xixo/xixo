package update

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/xixo/xixo/link/internal/release"
)

type Updater struct {
	Placer
	Requests string
	Results  string
	OS       string
	Arch     string
	Wait     time.Duration
	Poll     time.Duration
	Now      func() time.Time
	Vouch    *Vouch
}

func (u *Updater) settle() {
	if u.Wait == 0 {
		u.Wait = Probation
	}

	if u.Poll == 0 {
		u.Poll = 2 * time.Second
	}

	if u.Now == nil {
		u.Now = time.Now
	}
}

func (u *Updater) Apply(ctx context.Context) error {
	u.settle()

	if err := u.recover(ctx); err != nil {
		return err
	}

	if back, ok := u.askedBack(); ok {
		if u.handled(back) {
			return nil
		}

		err := u.rollBackTo(ctx, back)
		u.record(back, err)

		return err
	}

	staged, id := Staged(u.Staged())
	if staged == "" {
		return u.relay()
	}

	if id == u.Pointed(Current) || u.Refused(id) {
		return nil
	}

	asked := Request{}
	if Read(filepath.Join(staged, RequestKept), &asked) != nil || asked.Check() != nil {
		asked = Request{}
	}

	if asked.SHA256 != "" && u.handled(asked) {
		return nil
	}

	err := u.apply(ctx, staged, id, asked)
	if asked.SHA256 != "" {
		u.record(asked, err)
	}

	return err
}

func (u *Updater) apply(ctx context.Context, staged, id string, asked Request) error {
	raw, err := os.ReadFile(filepath.Join(staged, release.File))
	if err != nil {
		return err
	}

	bundle, err := os.ReadFile(filepath.Join(staged, release.Bundle))
	if err != nil && !missing(err) {
		return err
	}

	held, err := u.Vouch.Verify(raw, bundle)
	if err != nil {
		return err
	}

	if held.ID != id {
		return fmt.Errorf("the staged folder %s holds release %s", id, held.ID)
	}

	if asked.SHA256 != "" && asked.Release != "" && asked.Release != release.Sum(raw) {
		return fmt.Errorf("%w: the staged release is not the one xixo named", ErrNotInRelease)
	}

	_, goarch := system(u.OS, u.Arch)

	files, err := held.Linux(goarch)
	if err != nil {
		return err
	}

	if err := u.Keep(held, files, staged); err != nil {
		return err
	}

	u.log().Info("updating xixo link", "version", held.Version, "serial", held.Serial, "release", held.ID)

	from := u.Pointed(Good)
	since := u.Now()

	if err := u.switchTo(ctx, held.ID); err != nil {
		return err
	}

	if u.connected(ctx, files[0].SHA256, since) {
		if err := u.promote(ctx, held, from); err != nil {
			u.log().Warn("xixo link updated and connected, and what follows an update did not all happen", "error", err)
		}

		u.log().Info("xixo link updated and connected", "version", held.Version, "serial", held.Serial)

		return nil
	}

	if err := u.rollback(ctx, held.ID, from); err != nil {
		return fmt.Errorf("the new version did not connect, and the one before it could not be put back: %w", err)
	}

	return fmt.Errorf("version %s did not connect to xixo within %s, so xixo link went back to the release before it", held.Version, u.Wait)
}

func (u *Updater) switchTo(ctx context.Context, id string) error {
	changed, err := u.Render(id)
	if err != nil {
		return err
	}

	if err := u.Link(id); err != nil {
		return err
	}

	if err := u.Reload(ctx); err != nil {
		return err
	}

	if changed {
		return u.Restart(ctx)
	}

	return nil
}

func (u *Updater) promote(ctx context.Context, held Verified, before string) error {
	if err := u.Promote(held.ID); err != nil {
		return err
	}

	if err := u.Vouch.Accept(held.Release); err != nil {
		return err
	}

	os.Remove(u.Bad())

	if err := u.Enable(ctx); err != nil {
		return err
	}

	Prune(u.Releases(), before)

	if (&Packages{Layout: u.Layout}).Changed() {
		return u.run(ctx, "systemctl", "start", "--no-block", PackagesUnit)
	}

	return nil
}

func (u *Updater) rollback(ctx context.Context, bad, good string) error {
	u.log().Warn("the new xixo link did not connect, so the release before it is back", "release", bad, "good", good)

	if err := u.Refuse(bad); err != nil {
		return err
	}

	if good == "" {
		return errors.New("this machine holds no release that connected before")
	}

	if _, err := u.Render(good); err != nil {
		return err
	}

	if err := u.Link(good); err != nil {
		return err
	}

	if err := u.Reload(ctx); err != nil {
		return err
	}

	if err := u.Restart(ctx); err != nil {
		return err
	}

	Prune(u.Releases())

	return nil
}

func (u *Updater) recover(ctx context.Context) error {
	current, good := u.Pointed(Current), u.Pointed(Good)

	switch {
	case current == "":
		return nil
	case good == "":
		return u.Promote(current)
	case current == good:
		return nil
	}

	sha, err := Digest(filepath.Join(u.Release(current), Binary))
	if err != nil {
		return err
	}

	if u.running(sha, time.Time{}) {
		held, err := u.Held(current)
		if err != nil {
			return err
		}

		return u.promote(ctx, Verified{Release: held, ID: current}, good)
	}

	pointed, err := os.Lstat(filepath.Join(u.Releases(), Current))
	if err != nil {
		return err
	}

	if u.Now().Sub(pointed.ModTime()) < u.Wait {
		return nil
	}

	return u.rollback(ctx, current, good)
}

func (u *Updater) connected(ctx context.Context, sha string, since time.Time) bool {
	deadline := time.NewTimer(u.Wait)
	defer deadline.Stop()

	poll := time.NewTicker(u.Poll)
	defer poll.Stop()

	for {
		if u.running(sha, since) {
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

func (u *Updater) running(sha string, since time.Time) bool {
	held := Running{}

	return Read(filepath.Join(u.Requests, RunningFile), &held) == nil &&
		held.SHA256 == sha && !held.At.Before(since.Add(-time.Second))
}

func (u *Updater) relay() error {
	told := Result{}
	if Read(filepath.Join(u.Cache(), FetchFile), &told) != nil || told.OK || told.SHA256 == "" {
		return nil
	}

	asked := Request{Target: Target{Version: told.Version, SHA256: told.SHA256}, RequestedAt: told.RequestedAt}
	if u.handled(asked) {
		return nil
	}

	u.record(asked, errors.New(told.Error))

	return nil
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

	told := Result{Version: asked.Version, SHA256: asked.SHA256, RequestedAt: asked.RequestedAt, OK: err == nil, At: u.Now().UTC()}
	if err != nil {
		told.Error = err.Error()
	}

	if werr := Write(filepath.Join(u.Results, ResultFile), told, 0o644); werr != nil && !errors.Is(werr, os.ErrNotExist) {
		u.log().Warn("the update's result could not be kept", "error", werr)
	}
}

func (u *Updater) askedBack() (Request, bool) {
	asked := Request{}
	if Read(filepath.Join(u.Requests, RequestFile), &asked) != nil || !asked.RollBack || asked.Check() != nil || asked.Release == "" {
		return Request{}, false
	}

	return asked, true
}

func (u *Updater) rollBackTo(ctx context.Context, asked Request) error {
	id := asked.Release[:16]

	raw, err := os.ReadFile(filepath.Join(u.Release(id), release.File))
	if err != nil || release.Sum(raw) != asked.Release {
		return fmt.Errorf("this machine does not hold release %s", id)
	}

	sha, err := Digest(filepath.Join(u.Release(id), Binary))
	if err != nil || sha != asked.SHA256 {
		return fmt.Errorf("release %s on this machine is not the build xixo named", id)
	}

	left := u.Pointed(Current)
	if left == id {
		return nil
	}

	u.log().Info("going back to a release this machine holds", "version", asked.Version, "release", id)

	if _, err := u.Render(id); err != nil {
		return err
	}

	if err := u.Link(id); err != nil {
		return err
	}

	if err := u.Reload(ctx); err != nil {
		return err
	}

	if err := u.Restart(ctx); err != nil {
		return err
	}

	if err := u.Promote(id); err != nil {
		return err
	}

	Prune(u.Releases(), left)

	return nil
}
