package updates

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/verify"
)

func xixoKind(t *testing.T) Kind {
	t.Helper()
	kind, err := Named("xixo")
	if err != nil {
		t.Fatal(err)
	}

	return kind
}

func stack(t *testing.T, health string) (*fakeDocker, *Gate) {
	t.Helper()
	fake, docker := newDocker(t)
	kind := xixoKind(t)

	fake.image(&fakeImage{
		ID: "sha256:old", Digests: []string{kind.Image + "@" + running},
		Labels: map[string]string{Created: "2026-10-20T10:00:00Z", Revision: "old"},
		Env:    []string{"PATH=/usr/bin", "XIXO_REVISION=old"}, Health: "healthy", Cmd: []string{"./bin/thrust", "./bin/rails", "server"},
	}, kind.Local(Current))

	fake.published[kind.Image+"@"+built] = &fakeImage{
		ID: "sha256:new", Digests: []string{kind.Image + "@" + built},
		Labels: map[string]string{Created: "2026-10-21T11:52:24.722Z", Revision: "c589ffe682d3497df159d3615be691387ebea7d9"},
		Env:    []string{"PATH=/usr/bin", "XIXO_REVISION=new"}, Health: health, Cmd: []string{"./bin/thrust", "./bin/rails", "server"},
	}

	fake.run("xixo-worker-1", "worker", kind.Local(Current), "2", []string{"XIXO_TENANT=jon"})
	fake.run("xixo-xixo-1", "xixo", kind.Local(Current), "1", []string{"XIXO_TENANT=jon", "SECRET_KEY_BASE=kept"})

	return fake, &Gate{Docker: docker, Checker: trusted(t), Kinds: Kinds, Health: 2 * time.Second, Settled: 50 * time.Millisecond, Pause: 10 * time.Millisecond}
}

func signed(t *testing.T) Request {
	return Request{Kind: "xixo", Digest: built, Bundles: [][]byte{[]byte("{}"), bundle(t)}}
}

func TestAnAttestedBuildReplacesEachContainerInOrderAndKeepsWhatComposeSet(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()

	if err := gate.Pull(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	if err := gate.Swap(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	if fake.tags[LocalRepo+"xixo:current"] != "sha256:new" || fake.tags[LocalRepo+"xixo:previous"] != "sha256:old" {
		t.Fatalf("tags %v", fake.tags)
	}

	names := []string{}
	for _, container := range fake.containers {
		names = append(names, container.Name)
		if container.Image != "sha256:new" || !container.Running {
			t.Fatalf("%s runs %s, running %v", container.Name, container.Image, container.Running)
		}

		env := []string{}
		for _, entry := range container.Config["Env"].([]any) {
			env = append(env, entry.(string))
		}

		if !slices.Contains(env, "XIXO_REVISION=new") || slices.Contains(env, "XIXO_REVISION=old") || !slices.Contains(env, "XIXO_TENANT=jon") {
			t.Fatalf("%s env %v", container.Name, env)
		}

		labels := container.Config["Labels"].(map[string]any)
		if labels["com.docker.compose.image"] != "sha256:new" || labels[Revision] != "c589ffe682d3497df159d3615be691387ebea7d9" {
			t.Fatalf("%s labels %v", container.Name, labels)
		}

		if container.Config["Hostname"] != nil {
			t.Fatalf("%s kept the old hostname %v", container.Name, container.Config["Hostname"])
		}

		aliases := container.Networks["xixo_default"].(map[string]any)["Aliases"].([]any)
		if len(aliases) != 1 {
			t.Fatalf("%s aliases %v", container.Name, aliases)
		}
	}

	if !slices.Equal(names, []string{"/xixo-xixo-1", "/xixo-worker-1"}) {
		t.Fatalf("containers %v", names)
	}

	status, err := gate.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}

	for _, held := range status {
		if held.Name == "xixo" && (held.Current != built || held.Previous != running || len(held.Containers) != 2 || held.Containers[0].Health != "healthy") {
			t.Fatalf("status %+v", held)
		}
	}
}

func TestABuildWithoutAnAttestationIsNeitherPulledNorSwapped(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()
	unsigned := Request{Kind: "xixo", Digest: built, Bundles: [][]byte{[]byte("{}")}}

	if err := gate.Pull(ctx, unsigned); !errors.Is(err, verify.ErrUnsigned) {
		t.Fatalf("err %v", err)
	}

	if err := gate.Swap(ctx, unsigned); !errors.Is(err, verify.ErrUnsigned) {
		t.Fatalf("err %v", err)
	}

	if len(fake.pulls) != 0 || fake.tags[LocalRepo+"xixo:current"] != "sha256:old" {
		t.Fatalf("pulls %v tags %v", fake.pulls, fake.tags)
	}
}

func TestTheAttestationMustComeFromTheKindsOwnRepository(t *testing.T) {
	_, gate := stack(t, "healthy")
	request := signed(t)
	request.Kind = "masks"

	if err := gate.Pull(context.Background(), request); !errors.Is(err, verify.ErrUnsigned) {
		t.Fatalf("err %v", err)
	}

	request.Kind = "postgres"
	if err := gate.Pull(context.Background(), request); err == nil || !strings.Contains(err.Error(), "not something") {
		t.Fatalf("err %v", err)
	}
}

func TestASwapToABuildThatTurnsUnhealthyPutsEveryContainerBack(t *testing.T) {
	fake, gate := stack(t, "unhealthy")
	ctx := context.Background()

	if err := gate.Pull(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	if err := gate.Swap(ctx, signed(t)); err == nil {
		t.Fatal("an unhealthy build was kept")
	}

	if fake.tags[LocalRepo+"xixo:current"] != "sha256:old" {
		t.Fatalf("tags %v", fake.tags)
	}

	if len(fake.containers) != 2 {
		t.Fatalf("%d containers", len(fake.containers))
	}

	for _, container := range fake.containers {
		if container.Image != "sha256:old" || !container.Running || strings.HasSuffix(container.Name, "-next") || strings.HasSuffix(container.Name, "-previous") {
			t.Fatalf("%s runs %s, running %v", container.Name, container.Image, container.Running)
		}
	}
}

func TestAnOlderBuildIsRefused(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()
	fake.images["sha256:old"].Labels[Created] = "2026-10-22T00:00:00Z"

	gate.Pull(ctx, signed(t))
	if err := gate.Swap(ctx, signed(t)); !errors.Is(err, ErrOlder) {
		t.Fatalf("err %v", err)
	}

	if fake.tags[LocalRepo+"xixo:current"] != "sha256:old" {
		t.Fatalf("tags %v", fake.tags)
	}
}

func TestARollbackGoesBackToThePreviousBuild(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()

	if err := gate.Rollback(ctx, "xixo"); err == nil {
		t.Fatal("rolled back with no previous build")
	}

	gate.Pull(ctx, signed(t))
	if err := gate.Swap(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	if err := gate.Rollback(ctx, "xixo"); err != nil {
		t.Fatal(err)
	}

	for _, container := range fake.containers {
		if container.Image != "sha256:old" || !container.Running {
			t.Fatalf("%s runs %s", container.Name, container.Image)
		}
	}
}

func TestAContainerRunningAnotherImageIsLeftAlone(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()
	fake.image(&fakeImage{ID: "sha256:pinned", Health: "healthy"}, "ghcr.io/xixo/xixo:pinned")
	pinned := fake.run("xixo-pinned-1", "pinned", "ghcr.io/xixo/xixo:pinned", "", nil)
	pinned.Config["Labels"].(map[string]any)[Label] = "xixo"

	gate.Pull(ctx, signed(t))
	if err := gate.Swap(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	if pinned.Image != "sha256:pinned" || fake.container("xixo-pinned-1") != pinned {
		t.Fatal("the pinned container was replaced")
	}
}

func TestAFirstSwapOnlyTagsTheBuildAndMakesTheGateReady(t *testing.T) {
	fake, docker := newDocker(t)
	kind := xixoKind(t)
	fake.published[kind.Image+"@"+built] = &fakeImage{ID: "sha256:new", Digests: []string{kind.Image + "@" + built}, Labels: map[string]string{Created: "2026-10-21T11:52:24.722Z"}}
	gate := &Gate{Docker: docker, Checker: trusted(t), Kinds: []Kind{kind}}
	ctx := context.Background()

	if err := gate.Ready(ctx); err == nil {
		t.Fatal("ready with no build")
	}

	gate.Pull(ctx, signed(t))
	if err := gate.Swap(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	if err := gate.Ready(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestAContainerLeftOnAnOldBuildIsReportedAndMovedOnTheNextSwap(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()
	gate.Pull(ctx, signed(t))
	fake.tags[LocalRepo+"xixo:current"] = "sha256:new"

	status, _ := gate.Status(ctx)
	if !status[1].Containers[0].Stale {
		t.Fatalf("status %+v", status[1])
	}

	if err := gate.Swap(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	for _, container := range fake.containers {
		if container.Image != "sha256:new" {
			t.Fatalf("%s runs %s", container.Name, container.Image)
		}
	}

	status, _ = gate.Status(ctx)
	if status[1].Containers[0].Stale {
		t.Fatalf("status %+v", status[1])
	}
}

func TestAContainerWhoseImageIsGoneMovesWithTheNewImagesSettings(t *testing.T) {
	fake, gate := stack(t, "healthy")
	ctx := context.Background()
	gate.Pull(ctx, signed(t))
	fake.tags[LocalRepo+"xixo:current"] = "sha256:new"
	delete(fake.images, "sha256:old")

	if err := gate.Swap(ctx, signed(t)); err != nil {
		t.Fatal(err)
	}

	for _, container := range fake.containers {
		env := []string{}
		for _, entry := range container.Config["Env"].([]any) {
			env = append(env, entry.(string))
		}

		if container.Image != "sha256:new" || slices.Contains(env, "XIXO_REVISION=old") || !slices.Contains(env, "XIXO_REVISION=new") || !slices.Contains(env, "XIXO_TENANT=jon") {
			t.Fatalf("%s runs %s with %v", container.Name, container.Image, env)
		}

		if container.Config["Labels"].(map[string]any)[Revision] != "c589ffe682d3497df159d3615be691387ebea7d9" {
			t.Fatalf("%s labels %v", container.Name, container.Config["Labels"])
		}
	}
}

func TestTheGateSaysWhenItIsBusy(t *testing.T) {
	_, gate := stack(t, "healthy")

	if !gate.Idle() {
		t.Fatal("an idle gate said it was busy")
	}

	gate.lock.Lock()
	defer gate.lock.Unlock()

	if gate.Idle() {
		t.Fatal("a busy gate said it was idle")
	}
}
