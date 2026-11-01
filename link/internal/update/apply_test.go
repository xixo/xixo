package update

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/state"
)

const template = "[Service]\nUser=@USER@\n@FOLDERS@\nExecStart=x\n"

type testMachine struct {
	layout   Layout
	requests string
	results  string
	ran      *[]string
	old      string
	media    string
}

func recording() (*[]string, func(context.Context, string, ...string) error) {
	ran := &[]string{}

	return ran, func(_ context.Context, name string, args ...string) error {
		*ran = append(*ran, name+" "+strings.Join(args, " "))

		return nil
	}
}

func described(t *testing.T, version string, serial int64, packages []string, entries ...release.Entry) (release.Release, []byte) {
	t.Helper()
	held := release.Release{Version: version, Serial: serial, Revision: commit, Channel: release.Channel(version), PackagesApt: packages, Files: entries}
	raw, err := json.Marshal(held)
	if err != nil {
		t.Fatal(err)
	}

	return held, raw
}

func (m *testMachine) place(t *testing.T, dir string, raw []byte, files map[string][]byte) {
	t.Helper()

	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	os.WriteFile(filepath.Join(dir, release.File), raw, 0o644)

	for name, body := range files {
		mode := os.FileMode(0o644)
		if strings.HasPrefix(name, "xixo-link-linux") || name == Binary {
			mode = 0o755
		}

		if err := os.WriteFile(filepath.Join(dir, name), body, mode); err != nil {
			t.Fatal(err)
		}
	}
}

func machine(t *testing.T) *testMachine {
	t.Helper()
	root := t.TempDir()
	held := &testMachine{layout: Layout{Root: root}, requests: t.TempDir(), results: t.TempDir(), media: t.TempDir()}
	held.ran, _ = recording()

	old := script("echo 0.2.0")
	_, raw := described(t, "0.2.0", 10, []string{"poppler-utils"},
		entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, old),
		entry(Service, "", "", release.RoleUnit, []byte(template)),
		entry(FetchUnit, "", "", release.RoleUnit, []byte("fetch v1")))
	held.old = release.ID(raw)
	held.place(t, held.layout.Release(held.old), raw, map[string][]byte{Binary: old, Service: []byte(template), FetchUnit: []byte("fetch v1")})

	for _, pointer := range []string{Current, Good} {
		if err := Point(held.layout.Releases(), pointer, held.old); err != nil {
			t.Fatal(err)
		}
	}

	os.MkdirAll(held.layout.Etc(), 0o755)
	os.MkdirAll(held.layout.Units(), 0o755)

	if _, err := state.Setup(held.layout.Config(), "https://xixo.example", "https://id.example", []string{held.media}); err != nil {
		t.Fatal(err)
	}

	Write(held.layout.Install(), Installed{User: "jon"}, 0o644)
	Write(held.layout.Floor(), int64(10), 0o644)
	Write(held.layout.Packages(), []string{"poppler-utils"}, 0o644)

	config, _ := state.LoadConfig(held.layout.Config())
	rendered, _ := state.Unit(template, "jon", config.Folders)
	os.WriteFile(filepath.Join(held.layout.Units(), Service), []byte(rendered), 0o644)
	os.WriteFile(filepath.Join(held.layout.Units(), FetchUnit), []byte("fetch v1"), 0o644)

	return held
}

func (m *testMachine) stage(t *testing.T, fresh []byte, version string, serial int64, units map[string]string, bundle []byte) string {
	t.Helper()

	if units == nil {
		units = map[string]string{Service: template, FetchUnit: "fetch v1"}
	}

	entries := []release.Entry{entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh)}
	files := map[string][]byte{"xixo-link-linux-amd64": fresh}

	for name, body := range units {
		entries = append(entries, entry(name, "", "", release.RoleUnit, []byte(body)))
		files[name] = []byte(body)
	}

	_, raw := described(t, version, serial, release.Packages, entries...)
	id := release.ID(raw)
	dir := filepath.Join(m.layout.Staged(), id)
	pruned(m.layout.Staged(), "")
	m.place(t, dir, raw, files)

	if bundle != nil {
		os.WriteFile(filepath.Join(dir, release.Bundle), bundle, 0o644)
	}

	asked := Request{Target: Target{Version: version, SHA256: sum(fresh), Release: release.Sum(raw)}, From: "0.2.0", RequestedAt: time.Now().UTC()}
	Write(filepath.Join(dir, RequestKept), asked, 0o644)
	Write(filepath.Join(m.requests, RequestFile), asked, 0o644)

	return id
}

func (m *testMachine) updater(connects bool) *Updater {
	ran, run := recording()
	m.ran = ran

	held := &Updater{
		Placer:   Placer{Layout: m.layout, Run: run},
		Requests: m.requests, Results: m.results, OS: "linux", Arch: "amd64",
		Wait: 500 * time.Millisecond, Poll: 20 * time.Millisecond,
		Vouch: &Vouch{Unsigned: true, Floor: m.layout.Floor()},
	}

	if connects {
		go func() {
			deadline := time.Now().Add(5 * time.Second)

			for time.Now().Before(deadline) {
				if current := Pointed(m.layout.Releases(), Current); current != "" && current != m.old {
					sha, _ := Digest(filepath.Join(m.layout.Release(current), Binary))
					Write(filepath.Join(m.requests, RunningFile), Running{Version: "0.3.0", SHA256: sha, PID: 1, At: time.Now().UTC()}, 0o644)

					return
				}

				time.Sleep(10 * time.Millisecond)
			}
		}()
	}

	return held
}

func (m *testMachine) ranLine(want string) bool {
	for _, line := range *m.ran {
		if line == want {
			return true
		}
	}

	return false
}

func TestTheUpdaterInstallsAStagedReleaseThatConnects(t *testing.T) {
	held := machine(t)
	fresh := script("echo 0.3.0")
	id := held.stage(t, fresh, "0.3.0", 20, map[string]string{Service: template + "TimeoutStopSec=20s\n", FetchUnit: "fetch v2"}, nil)
	updater := held.updater(true)

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held.layout.Pointed(Current) != id || held.layout.Pointed(Good) != id {
		t.Fatalf("current %q good %q", held.layout.Pointed(Current), held.layout.Pointed(Good))
	}

	if sha, _ := Digest(held.layout.Binary()); sha != sum(fresh) {
		t.Fatal("the binary xixo link runs is not the new one")
	}

	if linked, _ := os.Readlink(held.layout.Binary()); linked != "releases/current/xixo-link" {
		t.Fatalf("the binary links to %q", linked)
	}

	unit, _ := os.ReadFile(filepath.Join(held.layout.Units(), Service))
	if !strings.Contains(string(unit), "User=jon\n") || !strings.Contains(string(unit), "TimeoutStopSec=20s") || !strings.Contains(string(unit), "BindReadOnlyPaths=\"-"+held.media+"\"") {
		t.Fatalf("unit %s", unit)
	}

	if fetch, _ := os.ReadFile(filepath.Join(held.layout.Units(), FetchUnit)); string(fetch) != "fetch v2" {
		t.Fatalf("fetch unit %q", fetch)
	}

	if floor, _ := Floor(held.layout.Floor()); floor != 20 {
		t.Fatalf("floor %d", floor)
	}

	if _, err := os.Stat(filepath.Join(held.layout.Release(held.old), Binary)); err != nil {
		t.Fatal("the release before was not kept for a rollback")
	}

	for _, want := range []string{
		"systemctl daemon-reload", "systemctl restart xixo-link",
		"systemctl enable --now --quiet xixo-link-update.path xixo-link-update.timer",
		"systemctl enable --now --quiet xixo-link-part@models.path",
		"systemctl start --no-block xixo-link-packages.service",
	} {
		if !held.ranLine(want) {
			t.Fatalf("did not run %q in:\n%s", want, strings.Join(*held.ran, "\n"))
		}
	}

	told := Result{}
	if err := Read(filepath.Join(held.results, ResultFile), &told); err != nil || !told.OK || told.Version != "0.3.0" {
		t.Fatalf("result %+v: %v", told, err)
	}

	before := len(*held.ran)
	if err := updater.Apply(context.Background()); err != nil || len(*held.ran) != before {
		t.Fatalf("applying a release already current: %v, ran %v", err, (*held.ran)[before:])
	}
}

func TestTheUpdaterGoesBackWhenTheNewReleaseDoesNotConnect(t *testing.T) {
	held := machine(t)
	id := held.stage(t, script("echo 0.3.0"), "0.3.0", 20, map[string]string{Service: template, FetchUnit: "fetch v2"}, nil)
	updater := held.updater(false)

	err := updater.Apply(context.Background())
	if err == nil || !strings.Contains(err.Error(), "did not connect") {
		t.Fatalf("apply: %v", err)
	}

	if held.layout.Pointed(Current) != held.old || held.layout.Pointed(Good) != held.old {
		t.Fatalf("current %q good %q", held.layout.Pointed(Current), held.layout.Pointed(Good))
	}

	if fetch, _ := os.ReadFile(filepath.Join(held.layout.Units(), FetchUnit)); string(fetch) != "fetch v1" {
		t.Fatalf("the old unit was not put back: %q", fetch)
	}

	if !held.layout.Refused(id) {
		t.Fatal("the release that failed is not marked bad")
	}

	if floor, _ := Floor(held.layout.Floor()); floor != 10 {
		t.Fatalf("a release that failed raised the floor to %d", floor)
	}

	told := Result{}
	if Read(filepath.Join(held.results, ResultFile), &told); told.OK || !strings.Contains(told.Error, "did not connect") {
		t.Fatalf("result %+v", told)
	}

	before := len(*held.ran)
	if err := updater.Apply(context.Background()); err != nil || len(*held.ran) != before {
		t.Fatalf("a release that failed was tried again: %v %v", err, (*held.ran)[before:])
	}
}

func TestTheUpdaterRefusesAStagedFileThatDoesNotMatchTheRelease(t *testing.T) {
	held := machine(t)
	id := held.stage(t, script("echo 0.3.0"), "0.3.0", 20, nil, nil)
	os.WriteFile(filepath.Join(held.layout.Staged(), id, "xixo-link-linux-amd64"), script("echo tampered"), 0o755)

	if err := held.updater(true).Apply(context.Background()); !errors.Is(err, ErrMismatch) {
		t.Fatalf("apply: %v", err)
	}

	if held.layout.Pointed(Current) != held.old || regular(filepath.Join(held.layout.Release(id), Binary)) {
		t.Fatal("a file that did not match was kept")
	}

	held.stage(t, script("echo 0.1.0"), "0.1.0", 5, nil, nil)

	if err := held.updater(true).Apply(context.Background()); !errors.Is(err, ErrOlderRelease) {
		t.Fatalf("an older release gave %v", err)
	}
}

func TestABinaryOnlyChangeLeavesTheRestartToXixoLink(t *testing.T) {
	held := machine(t)
	held.stage(t, script("echo 0.3.0"), "0.3.0", 20, nil, nil)

	if err := held.updater(true).Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held.ranLine("systemctl restart xixo-link") {
		t.Fatal("xixo link was restarted although no unit changed")
	}

	if !held.ranLine("systemctl daemon-reload") {
		t.Fatal("systemd was not told about the new release")
	}
}

func TestTheUpdaterRecoversAReleaseLeftHalfWay(t *testing.T) {
	held := machine(t)
	fresh := script("echo 0.3.0")
	_, raw := described(t, "0.3.0", 20, nil, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh), entry(Service, "", "", release.RoleUnit, []byte(template)))
	id := release.ID(raw)
	held.place(t, held.layout.Release(id), raw, map[string][]byte{Binary: fresh, Service: []byte(template)})
	Point(held.layout.Releases(), Current, id)

	updater := held.updater(false)
	updater.Now = func() time.Time { return time.Now().Add(10 * time.Minute) }

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held.layout.Pointed(Current) != held.old || !held.ranLine("systemctl restart xixo-link") || !held.layout.Refused(id) {
		t.Fatalf("a release that never connected stayed current: %q, ran %v", held.layout.Pointed(Current), *held.ran)
	}

	connected := machine(t)
	connected.place(t, connected.layout.Release(id), raw, map[string][]byte{Binary: fresh, Service: []byte(template)})
	Point(connected.layout.Releases(), Current, id)
	Write(filepath.Join(connected.requests, RunningFile), Running{Version: "0.3.0", SHA256: sum(fresh), PID: 1, At: time.Now().UTC()}, 0o644)

	if err := connected.updater(false).Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if floor, _ := Floor(connected.layout.Floor()); connected.layout.Pointed(Good) != id || floor != 20 {
		t.Fatalf("a release that connected was not promoted: good %q floor %d", connected.layout.Pointed(Good), floor)
	}
}

func TestAFetchFailureReachesTheResultXixoLinkReads(t *testing.T) {
	held := machine(t)
	os.MkdirAll(held.layout.Cache(), 0o755)
	asked := Request{Target: Target{Version: "0.3.0", SHA256: strings.Repeat("2", 64)}, RequestedAt: time.Now().UTC()}
	Write(filepath.Join(held.layout.Cache(), FetchFile), Result{Version: "0.3.0", SHA256: asked.SHA256, RequestedAt: asked.RequestedAt, Error: "no attestation checks out", At: time.Now()}, 0o644)

	if err := held.updater(false).Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	told := Result{}
	if Read(filepath.Join(held.results, ResultFile), &told); told.OK || told.Error != "no attestation checks out" || !told.RequestedAt.Equal(asked.RequestedAt) {
		t.Fatalf("result %+v", told)
	}
}

func TestTheUpdaterGoesBackToAReleaseItHoldsWhenXixoAsks(t *testing.T) {
	held := machine(t)
	fresh := script("echo 0.3.0")
	id := held.stage(t, fresh, "0.3.0", 20, nil, nil)
	updater := held.updater(true)

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	raw, _ := os.ReadFile(filepath.Join(held.layout.Release(held.old), release.File))
	old, _ := Digest(filepath.Join(held.layout.Release(held.old), Binary))
	asked := Request{Target: Target{Version: "0.2.0", SHA256: old, Release: release.Sum(raw)}, From: "0.3.0", RequestedAt: time.Now().UTC(), RollBack: true}
	Write(filepath.Join(held.requests, RequestFile), asked, 0o644)
	before := len(*held.ran)

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held.layout.Pointed(Current) != held.old || held.layout.Pointed(Good) != held.old {
		t.Fatalf("current %q good %q", held.layout.Pointed(Current), held.layout.Pointed(Good))
	}

	if !held.ranLine("systemctl restart xixo-link") || len(*held.ran) == before {
		t.Fatalf("xixo link was not restarted into the release before:\n%s", strings.Join((*held.ran)[before:], "\n"))
	}

	if floor, _ := Floor(held.layout.Floor()); floor != 20 {
		t.Fatalf("going back lowered the floor to %d", floor)
	}

	if _, err := os.Stat(filepath.Join(held.layout.Release(id), Binary)); err != nil {
		t.Fatal("the release xixo link left was not kept")
	}

	told := Result{}
	if err := Read(filepath.Join(held.results, ResultFile), &told); err != nil || !told.OK || told.Version != "0.2.0" {
		t.Fatalf("result %+v: %v", told, err)
	}

	again := len(*held.ran)
	if err := updater.Apply(context.Background()); err != nil || len(*held.ran) != again {
		t.Fatalf("the same request was taken twice: %v %v", err, (*held.ran)[again:])
	}

	asked.Release = strings.Repeat("e", 64)
	asked.RequestedAt = time.Now().UTC()
	Write(filepath.Join(held.requests, RequestFile), asked, 0o644)

	if err := updater.Apply(context.Background()); err == nil || !strings.Contains(err.Error(), "does not hold") {
		t.Fatalf("a release this machine lacks gave %v", err)
	}
}
