package update

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/xixo/xixo/link/internal/release"
)

func wanting(t *testing.T, packages []string) Layout {
	t.Helper()
	layout := Layout{Root: t.TempDir()}
	_, raw := described(t, "0.3.0", 20, packages, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, []byte("b")))
	id := release.ID(raw)
	os.MkdirAll(layout.Release(id), 0o755)
	os.WriteFile(layout.Release(id)+"/"+release.File, raw, 0o644)
	os.WriteFile(layout.Release(id)+"/"+Binary, []byte("b"), 0o755)
	Point(layout.Releases(), Current, id)

	return layout
}

func TestPackagesComeFromTheReleaseAndAreInstalledOnce(t *testing.T) {
	layout := wanting(t, []string{"poppler-utils", "ffmpeg"})
	ran, run := recording()
	out := &bytes.Buffer{}
	held := &Packages{Layout: layout, Run: run, Out: out, LookPath: func(string) (string, error) { return "/usr/bin/apt-get", nil }}

	if !held.Changed() {
		t.Fatal("a fresh list is not seen as a change")
	}

	if err := held.Install(context.Background()); err != nil {
		t.Fatal(err)
	}

	want := []string{
		"env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -q update",
		"env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -q install -y --no-install-recommends -- poppler-utils ffmpeg",
	}
	if strings.Join(*ran, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran:\n%s", strings.Join(*ran, "\n"))
	}

	if !strings.Contains(out.String(), "with apt. This can take a few minutes.") {
		t.Fatalf("said %q", out)
	}

	if held.Changed() {
		t.Fatal("the list installed is still seen as a change")
	}

	if err := held.Install(context.Background()); err != nil || len(*ran) != 2 {
		t.Fatalf("installing again: %v, ran %v", err, *ran)
	}
}

func TestAFailedAptLeavesTheListForNextTime(t *testing.T) {
	layout := wanting(t, []string{"poppler-utils"})
	held := &Packages{Layout: layout, LookPath: func(string) (string, error) { return "/usr/bin/apt-get", nil },
		Run: func(_ context.Context, _ string, args ...string) error {
			if strings.Contains(strings.Join(args, " "), " install ") {
				return errors.New("E: unable to locate")
			}

			return nil
		}}

	if err := held.Install(context.Background()); err == nil || !strings.Contains(err.Error(), "reads the files it can") {
		t.Fatalf("install: %v", err)
	}

	if !held.Changed() {
		t.Fatal("a failed install was recorded as done")
	}
}

func TestAMachineWithoutAptSkipsThePackagesWithANote(t *testing.T) {
	layout := wanting(t, []string{"poppler-utils"})
	ran, run := recording()
	out := &bytes.Buffer{}
	held := &Packages{Layout: layout, Run: run, Out: out, LookPath: func(string) (string, error) { return "", errors.New("not found") }}

	if err := held.Install(context.Background()); err != nil || len(*ran) != 0 {
		t.Fatalf("install: %v ran %v", err, *ran)
	}

	if !strings.Contains(out.String(), "since this system has no apt") || held.Changed() {
		t.Fatalf("said %q, changed %v", out, held.Changed())
	}
}
