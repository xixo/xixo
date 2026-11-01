package updates

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/xixo/xixo/link/internal/verify"
)

const (
	HealthWithin = 5 * time.Minute
	Settle       = 30 * time.Second
	StopWithin   = 30 * time.Second
	MostBundles  = 8
)

var ErrOlder = errors.New("the image is older than the one running")

type Gate struct {
	Docker  *Docker
	Checker func() (*verify.Checker, error)
	Kinds   []Kind
	Log     *slog.Logger
	Health  time.Duration
	Settled time.Duration
	Pause   time.Duration

	lock sync.Mutex
}

type Request struct {
	Kind    string   `json:"kind"`
	Digest  string   `json:"digest"`
	Bundles [][]byte `json:"bundles,omitempty"`
}

type Running struct {
	Name    string `json:"name"`
	Service string `json:"service,omitempty"`
	State   string `json:"state"`
	Health  string `json:"health,omitempty"`
	Stale   bool   `json:"stale,omitempty"`
}

type Held struct {
	Name             string    `json:"name"`
	Current          string    `json:"current,omitempty"`
	Previous         string    `json:"previous,omitempty"`
	PreviousRevision string    `json:"previous_revision,omitempty"`
	PreviousVersion  string    `json:"previous_version,omitempty"`
	Created          string    `json:"created,omitempty"`
	Revision         string    `json:"revision,omitempty"`
	Version          string    `json:"version,omitempty"`
	Containers       []Running `json:"containers"`
}

func (g *Gate) kind(name string) (Kind, error) {
	for _, kind := range g.Kinds {
		if kind.Name == name {
			return kind, nil
		}
	}

	return Kind{}, fmt.Errorf("%q is not something this gate keeps up to date", name)
}

func (g *Gate) checked(request Request) (Kind, verify.Signed, error) {
	kind, err := g.kind(request.Kind)
	if err != nil {
		return Kind{}, verify.Signed{}, err
	}

	checker, err := g.Checker()
	if err != nil {
		return Kind{}, verify.Signed{}, err
	}

	if len(request.Bundles) > MostBundles {
		request.Bundles = request.Bundles[:MostBundles]
	}

	failed := verify.ErrUnsigned
	for _, bundle := range request.Bundles {
		signed, err := checker.Check(bundle, request.Digest, kind.Signer)
		if err == nil {
			return kind, signed, nil
		}

		failed = err
	}

	return Kind{}, verify.Signed{}, fmt.Errorf("%s@%s: %w", kind.Image, request.Digest, failed)
}

func (g *Gate) Pull(ctx context.Context, request Request) error {
	g.lock.Lock()
	defer g.lock.Unlock()

	kind, signed, err := g.checked(request)
	if err != nil {
		g.log().Warn("refused a pull", "kind", request.Kind, "digest", request.Digest, "error", err)
		return err
	}

	if err := g.Docker.Pull(ctx, kind.Image, request.Digest); err != nil {
		return err
	}

	if _, err := g.pulled(ctx, kind, request.Digest); err != nil {
		return err
	}

	g.log().Info("pulled", "kind", kind.Name, "digest", request.Digest, "commit", signed.Commit, "workflow", signed.Workflow)

	return nil
}

func (g *Gate) pulled(ctx context.Context, kind Kind, digest string) (Image, error) {
	reference := kind.Image + "@" + digest
	image, err := g.Docker.Image(ctx, reference)
	if err != nil {
		return Image{}, err
	}

	if !slices.Contains(image.RepoDigests, reference) {
		return Image{}, fmt.Errorf("docker holds %s under %v, not %s", image.ID, image.RepoDigests, reference)
	}

	return image, nil
}

func (g *Gate) Swap(ctx context.Context, request Request) error {
	g.lock.Lock()
	defer g.lock.Unlock()

	kind, signed, err := g.checked(request)
	if err != nil {
		g.log().Warn("refused a swap", "kind", request.Kind, "digest", request.Digest, "error", err)
		return err
	}

	image, err := g.pulled(ctx, kind, request.Digest)
	if err != nil {
		return err
	}

	current, err := g.Docker.Image(ctx, kind.Local(Current))
	held := err == nil
	if err != nil && !errors.Is(err, ErrNoImage) {
		return err
	}

	if held && current.ID == image.ID {
		return g.moved(ctx, kind, image, nil)
	}

	if held && image.Config.Labels[Created] < current.Config.Labels[Created] {
		g.log().Warn("refused a swap", "kind", kind.Name, "digest", request.Digest, "error", ErrOlder)
		return fmt.Errorf("%s@%s: %w", kind.Image, request.Digest, ErrOlder)
	}

	if held {
		if err := g.Docker.Tag(ctx, current.ID, kind.Local(Previous)); err != nil {
			return err
		}
	}

	if err := g.Docker.Tag(ctx, image.ID, kind.Local(Current)); err != nil {
		return err
	}

	g.log().Info("swapping", "kind", kind.Name, "digest", request.Digest, "commit", signed.Commit)

	if !held {
		return nil
	}

	return g.moved(ctx, kind, image, &current)
}

func (g *Gate) Rollback(ctx context.Context, name string) error {
	g.lock.Lock()
	defer g.lock.Unlock()

	kind, err := g.kind(name)
	if err != nil {
		return err
	}

	previous, err := g.Docker.Image(ctx, kind.Local(Previous))
	if err != nil {
		return fmt.Errorf("%s has no previous build to roll back to: %w", kind.Name, err)
	}

	current, err := g.Docker.Image(ctx, kind.Local(Current))
	if err != nil {
		return err
	}

	if current.ID == previous.ID {
		return g.moved(ctx, kind, previous, nil)
	}

	if err := g.Docker.Tag(ctx, previous.ID, kind.Local(Current)); err != nil {
		return err
	}

	g.log().Info("rolling back", "kind", kind.Name, "to", previous.ID)

	return g.moved(ctx, kind, previous, &current)
}

func (g *Gate) moved(ctx context.Context, kind Kind, to Image, back *Image) error {
	containers, err := g.labeled(ctx, kind)
	if err != nil {
		return err
	}

	done := []Listed{}

	for _, container := range containers {
		if container.Image == to.ID {
			continue
		}

		if err := g.replace(ctx, kind, container.ID, to); err != nil {
			g.log().Warn("a container did not come up on the new build, so it goes back", "kind", kind.Name, "container", name(container), "error", err)

			if back != nil {
				quiet := context.WithoutCancel(ctx)
				g.Docker.Tag(quiet, back.ID, kind.Local(Current))

				for _, undone := range slices.Backward(done) {
					if listed, err := g.find(quiet, name(undone)); err == nil {
						g.replace(quiet, kind, listed.ID, *back)
					}
				}
			}

			return fmt.Errorf("%s did not come up: %w", name(container), err)
		}

		done = append(done, container)
	}

	return nil
}

func (g *Gate) labeled(ctx context.Context, kind Kind) ([]Listed, error) {
	listed, err := g.Docker.Labeled(ctx)
	if err != nil {
		return nil, err
	}

	held := []Listed{}
	for _, container := range listed {
		if container.Labels[Label] != kind.Name || strings.HasSuffix(name(container), "-next") || strings.HasSuffix(name(container), "-previous") {
			continue
		}

		inspected, err := g.Docker.Inspect(ctx, container.ID)
		if err != nil {
			return nil, err
		}

		if configured := object(inspected["Config"])["Image"]; configured != kind.Local(Current) {
			g.log().Warn("a labeled container runs another image, so the updater leaves it alone", "container", name(container), "image", configured, "wanted", kind.Local(Current))
			continue
		}

		held = append(held, container)
	}

	sort.SliceStable(held, func(a, b int) bool {
		left, _ := strconv.Atoi(held[a].Labels[OrderLabel])
		right, _ := strconv.Atoi(held[b].Labels[OrderLabel])
		if left != right {
			return left < right
		}

		return name(held[a]) < name(held[b])
	})

	return held, nil
}

func (g *Gate) find(ctx context.Context, wanted string) (Listed, error) {
	listed, err := g.Docker.Labeled(ctx)
	if err != nil {
		return Listed{}, err
	}

	for _, container := range listed {
		if name(container) == wanted {
			return container, nil
		}
	}

	return Listed{}, fmt.Errorf("no container is named %s", wanted)
}

func name(container Listed) string {
	if len(container.Names) == 0 {
		return container.ID
	}

	return strings.TrimPrefix(container.Names[0], "/")
}

func (g *Gate) replace(ctx context.Context, kind Kind, id string, to Image) error {
	inspected, err := g.Docker.Inspect(ctx, id)
	if err != nil {
		return err
	}

	from, err := g.Docker.Image(ctx, fmt.Sprint(inspected["Image"]))
	gone := errors.Is(err, ErrNoImage)
	if err != nil && !gone {
		return err
	}

	if gone {
		g.log().Warn("the image a container runs is gone, so every setting the new image names comes from the new image", "container", inspected["Name"], "image", inspected["Image"])
		from = Keyed(to)
	}

	body, err := Recreated(inspected, from, kind.Local(Current), to.ID)
	if err != nil {
		return err
	}

	called := strings.TrimPrefix(fmt.Sprint(inspected["Name"]), "/")
	running := object(inspected["State"])["Running"] == true

	g.Docker.Remove(ctx, called+"-next")
	g.Docker.Remove(ctx, called+"-previous")

	next, err := g.Docker.Create(ctx, called+"-next", body)
	if err != nil {
		return err
	}

	restore := func(cause error) error {
		quiet := context.WithoutCancel(ctx)
		g.Docker.Remove(quiet, next)
		g.Docker.Rename(quiet, id, called)
		if running {
			g.Docker.Start(quiet, id)
		}

		return cause
	}

	if err := g.Docker.Stop(ctx, id, StopWithin); err != nil {
		return restore(err)
	}

	if err := g.Docker.Rename(ctx, id, called+"-previous"); err != nil {
		return restore(err)
	}

	if err := g.Docker.Rename(ctx, next, called); err != nil {
		return restore(err)
	}

	if running {
		if err := g.Docker.Start(ctx, next); err != nil {
			g.Docker.Rename(context.WithoutCancel(ctx), next, called+"-next")
			return restore(err)
		}

		if err := g.healthy(ctx, next); err != nil {
			g.Docker.Stop(context.WithoutCancel(ctx), next, StopWithin)
			g.Docker.Rename(context.WithoutCancel(ctx), next, called+"-next")
			return restore(err)
		}
	}

	g.Docker.Remove(ctx, id)
	g.log().Info("replaced", "kind", kind.Name, "container", called, "image", to.ID)

	return nil
}

func (g *Gate) healthy(ctx context.Context, id string) error {
	within := g.Health
	if within == 0 {
		within = HealthWithin
	}

	settled := g.Settled
	if settled == 0 {
		settled = Settle
	}

	pause := g.Pause
	if pause == 0 {
		pause = 2 * time.Second
	}

	deadline := time.Now().Add(within)
	started := time.Now()

	for {
		inspected, err := g.Docker.Inspect(ctx, id)
		if err != nil {
			return err
		}

		state := object(inspected["State"])
		health, checked := object(state["Health"])["Status"].(string)
		restarts, _ := inspected["RestartCount"].(float64)

		switch {
		case state["Running"] != true || state["Restarting"] == true || restarts > 0:
			return fmt.Errorf("it stopped: %v", state["Status"])
		case checked && health == "healthy":
			return nil
		case checked && health == "unhealthy":
			return errors.New("docker reports it unhealthy")
		case !checked && time.Since(started) >= settled:
			return nil
		case time.Now().After(deadline):
			return fmt.Errorf("it was not healthy within %s", within)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pause):
		}
	}
}

func (g *Gate) Status(ctx context.Context) ([]Held, error) {
	held := []Held{}

	for _, kind := range g.Kinds {
		status := Held{Name: kind.Name, Containers: []Running{}}

		currentID := ""
		if current, err := g.Docker.Image(ctx, kind.Local(Current)); err == nil {
			currentID = current.ID
			status.Current = digested(current, kind)
			status.Created = current.Config.Labels[Created]
			status.Revision = current.Config.Labels[Revision]
			status.Version = current.Config.Labels[Version]
		} else if !errors.Is(err, ErrNoImage) {
			return nil, err
		}

		if previous, err := g.Docker.Image(ctx, kind.Local(Previous)); err == nil {
			status.Previous = digested(previous, kind)
			status.PreviousRevision = previous.Config.Labels[Revision]
			status.PreviousVersion = previous.Config.Labels[Version]
		}

		containers, err := g.labeled(ctx, kind)
		if err != nil {
			return nil, err
		}

		for _, container := range containers {
			running := Running{Name: name(container), Service: container.Labels["com.docker.compose.service"], State: container.State, Stale: container.Image != currentID}
			if inspected, err := g.Docker.Inspect(ctx, container.ID); err == nil {
				running.Health, _ = object(object(inspected["State"])["Health"])["Status"].(string)
			}

			status.Containers = append(status.Containers, running)
		}

		held = append(held, status)
	}

	return held, nil
}

func digested(image Image, kind Kind) string {
	for _, reference := range image.RepoDigests {
		if digest, found := strings.CutPrefix(reference, kind.Image+"@"); found {
			return digest
		}
	}

	return ""
}

func (g *Gate) Idle() bool {
	if !g.lock.TryLock() {
		return false
	}

	g.lock.Unlock()

	return true
}

func (g *Gate) Ready(ctx context.Context) error {
	for _, kind := range g.Kinds {
		if _, err := g.Docker.Image(ctx, kind.Local(Current)); err != nil {
			return fmt.Errorf("%s has no build yet: %w", kind.Name, err)
		}
	}

	return nil
}

func (g *Gate) log() *slog.Logger {
	if g.Log == nil {
		return slog.Default()
	}

	return g.Log
}
