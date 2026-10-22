package updates

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"slices"
	"strconv"
	"time"

	"github.com/xixo/xixo/link/internal/verify"
)

const (
	Every    = 15 * time.Minute
	Watching = 5 * time.Minute
	Polled   = 15 * time.Second
	Retry    = time.Minute
)

var release = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)$`)

type Gated interface {
	Status(ctx context.Context) ([]Held, error)
	Pull(ctx context.Context, request Request) error
	Swap(ctx context.Context, request Request) error
	Rollback(ctx context.Context, kind string) error
}

type Registry interface {
	Digest(ctx context.Context, image, tag string) (string, error)
	Tags(ctx context.Context, image string) ([]string, error)
	Bundles(ctx context.Context, image, digest string) ([][]byte, error)
}

type Watcher struct {
	Gate     Gated
	Registry Registry
	Checker  func() (*verify.Checker, error)
	Channel  string
	Book     *Book
	Log      *slog.Logger
	Every    time.Duration
	Watching time.Duration
	Polled   time.Duration
	Retry    time.Duration
}

type planned struct {
	kind    Kind
	digest  string
	bundles [][]byte
}

func (w *Watcher) Run(ctx context.Context) error {
	for {
		pause := or(w.Every, Every)

		if err := w.Once(ctx); err != nil {
			w.log().Warn("the check for updates failed", "error", err)
			w.Book.Note(Event{Action: "check", Error: err.Error()})
			pause = min(pause, or(w.Retry, Retry))
		}

		select {
		case <-ctx.Done():
			return nil
		case <-w.Book.Asked():
		case <-time.After(pause):
		}
	}
}

func (w *Watcher) channel() string {
	return w.Book.Channel(w.Channel)
}

func (w *Watcher) Once(ctx context.Context) error {
	if w.Book.TakeRollBack() {
		if err := w.rolledBack(ctx); err != nil {
			return err
		}
	}

	if w.Book.Paused() {
		held, err := w.Gate.Status(ctx)
		if err != nil {
			return fmt.Errorf("the gate did not answer: %w", err)
		}

		w.Book.Checked(w.channel(), held, nil)

		return nil
	}

	checker, err := w.Checker()
	if err != nil {
		return err
	}

	held, err := w.Gate.Status(ctx)
	if err != nil {
		return fmt.Errorf("the gate did not answer: %w", err)
	}

	plan := []planned{}
	targets := map[string]string{}

	for _, status := range held {
		kind, err := Named(status.Name)
		if err != nil {
			continue
		}

		next, err := w.wanted(ctx, kind, status, checker)
		if err != nil {
			w.log().Warn("no build to update to", "kind", kind.Name, "error", err)
			w.Book.Note(Event{Action: "refuse", Kind: kind.Name, Error: err.Error()})
			continue
		}

		if next.digest != "" {
			targets[kind.Name] = next.digest
			plan = append(plan, next)
		}
	}

	w.Book.Checked(w.channel(), held, targets)

	pulled := []planned{}
	for _, next := range plan {
		if err := w.Gate.Pull(ctx, Request{Kind: next.kind.Name, Digest: next.digest, Bundles: next.bundles}); err != nil {
			w.Book.Note(Event{Action: "pull", Kind: next.kind.Name, Digest: next.digest, Error: err.Error()})
			continue
		}

		w.Book.Note(Event{Action: "pull", Kind: next.kind.Name, Digest: next.digest})
		pulled = append(pulled, next)
	}

	swapped := []planned{}
	for _, next := range pulled {
		if err := w.Gate.Swap(ctx, Request{Kind: next.kind.Name, Digest: next.digest, Bundles: next.bundles}); err != nil {
			w.log().Warn("the swap failed and the gate put the build back", "kind", next.kind.Name, "digest", next.digest, "error", err)
			w.Book.Note(Event{Action: "swap", Kind: next.kind.Name, Digest: next.digest, Error: err.Error()})
			w.Book.Bad(next.digest)
			w.back(ctx, swapped)

			return nil
		}

		w.log().Info("updated", "kind", next.kind.Name, "digest", next.digest)
		w.Book.Note(Event{Action: "swap", Kind: next.kind.Name, Digest: next.digest})
		swapped = append(swapped, next)
	}

	if len(swapped) == 0 {
		return nil
	}

	if during, err := w.Gate.Status(ctx); err == nil {
		w.Book.Checked(w.channel(), during, targets)
	}

	if err := w.watch(ctx, swapped); err != nil {
		w.log().Warn("an updated service failed while it was watched, so the updates roll back", "error", err)
		w.Book.Note(Event{Action: "watch", Error: err.Error()})
		for _, next := range swapped {
			w.Book.Bad(next.digest)
		}
		w.back(ctx, swapped)
	}

	after, err := w.Gate.Status(ctx)
	if err == nil {
		w.Book.Checked(w.channel(), after, targets)
	}

	return nil
}

func (w *Watcher) wanted(ctx context.Context, kind Kind, status Held, checker *verify.Checker) (planned, error) {
	signer, err := kind.On(w.channel())
	if err != nil {
		return planned{}, err
	}

	digest, err := w.latest(ctx, kind)
	if err != nil {
		return planned{}, err
	}

	stale := slices.ContainsFunc(status.Containers, func(running Running) bool { return running.Stale })
	if digest == status.Current && !stale || w.Book.IsBad(digest) {
		return planned{}, nil
	}

	bundles, err := w.Registry.Bundles(ctx, kind.Image, digest)
	if err != nil {
		return planned{}, err
	}

	for _, bundle := range bundles {
		if _, err := checker.Check(bundle, digest, signer); err == nil {
			return planned{kind: kind, digest: digest, bundles: bundles}, nil
		}
	}

	w.Book.Bad(digest)

	return planned{}, fmt.Errorf("%s@%s carries no attestation from %s %v: %w", kind.Image, digest, signer.Repository, signer.Workflows, verify.ErrUnsigned)
}

func (w *Watcher) latest(ctx context.Context, kind Kind) (string, error) {
	if w.channel() == Main {
		return w.Registry.Digest(ctx, kind.Image, Main)
	}

	tags, err := w.Registry.Tags(ctx, kind.Image)
	if err != nil {
		return "", err
	}

	highest := Highest(tags)
	if highest == "" {
		return "", errors.New("no release is published yet")
	}

	return w.Registry.Digest(ctx, kind.Image, highest)
}

func Highest(tags []string) string {
	best, bestParts := "", []int{-1, -1, -1}

	for _, tag := range tags {
		found := release.FindStringSubmatch(tag)
		if found == nil {
			continue
		}

		parts := []int{}
		for _, part := range found[1:] {
			number, err := strconv.Atoi(part)
			if err != nil {
				parts = nil
				break
			}
			parts = append(parts, number)
		}

		if parts != nil && slices.Compare(parts, bestParts) > 0 {
			best, bestParts = tag, parts
		}
	}

	return best
}

func (w *Watcher) watch(ctx context.Context, swapped []planned) error {
	deadline := time.Now().Add(or(w.Watching, Watching))
	names := map[string]bool{}
	for _, next := range swapped {
		names[next.kind.Name] = true
	}

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(or(w.Polled, Polled)):
		}

		held, err := w.Gate.Status(ctx)
		if err != nil {
			continue
		}

		for _, status := range held {
			if !names[status.Name] {
				continue
			}

			for _, container := range status.Containers {
				if container.State != "running" || container.Health == "unhealthy" {
					return fmt.Errorf("%s is %s %s", container.Name, container.State, container.Health)
				}
			}
		}
	}

	return nil
}

func (w *Watcher) back(ctx context.Context, swapped []planned) {
	for _, next := range slices.Backward(swapped) {
		err := w.Gate.Rollback(context.WithoutCancel(ctx), next.kind.Name)
		event := Event{Action: "rollback", Kind: next.kind.Name, Digest: next.digest}
		if err != nil {
			event.Error = err.Error()
			w.log().Error("the rollback failed; the service needs attention", "kind", next.kind.Name, "error", err)
		}
		w.Book.Note(event)
	}
}

func (w *Watcher) log() *slog.Logger {
	if w.Log == nil {
		return slog.Default()
	}

	return w.Log
}

func or(held, fallback time.Duration) time.Duration {
	if held == 0 {
		return fallback
	}

	return held
}

func (w *Watcher) rolledBack(ctx context.Context) error {
	held, err := w.Gate.Status(ctx)
	if err != nil {
		return fmt.Errorf("the gate did not answer: %w", err)
	}

	back := []planned{}
	for _, status := range held {
		kind, err := Named(status.Name)
		if err != nil || status.Previous == "" || status.Previous == status.Current {
			continue
		}

		w.Book.Bad(status.Current)
		back = append(back, planned{kind: kind, digest: status.Current})
	}

	if len(back) == 0 {
		w.Book.Note(Event{Action: "rollback", Error: "there is no previous build to roll back to"})
		return nil
	}

	w.back(ctx, back)

	return nil
}
