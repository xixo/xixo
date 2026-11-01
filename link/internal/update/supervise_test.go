package update

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/release"
)

func connects(state string, then string) []byte {
	return script(fmt.Sprintf(`printf '{"version":"0.3.0","sha256":"","pid":%%d,"at":"%%s"}' $$ "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" > %q/running.json
%s`, state, then))
}

func staged(t *testing.T, releases, name string, body []byte) {
	t.Helper()

	os.MkdirAll(filepath.Join(releases, name), 0o700)

	if err := os.WriteFile(filepath.Join(releases, name, Binary), body, 0o755); err != nil {
		t.Fatal(err)
	}
}

func supervisor(t *testing.T, self []byte) *Supervisor {
	t.Helper()

	root := t.TempDir()
	path := filepath.Join(root, "bin", Binary)
	os.MkdirAll(filepath.Dir(path), 0o700)
	os.WriteFile(path, self, 0o755)
	state := filepath.Join(root, "state")
	os.MkdirAll(state, 0o700)

	return &Supervisor{
		Self: path, Releases: filepath.Join(root, "releases"), State: state,
		Probation: 2 * time.Second, Poll: 20 * time.Millisecond, Pause: time.Millisecond,
	}
}

func supervised(t *testing.T, held *Supervisor) int {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	status := held.Run(ctx)
	if ctx.Err() != nil {
		t.Fatal("the supervisor did not finish")
	}

	return status
}

func TestTheSupervisorRunsItselfUntilThereIsARelease(t *testing.T) {
	held := supervisor(t, script("exit 3"))

	if status := supervised(t, held); status != 3 {
		t.Fatalf("status %d", status)
	}
}

func TestTheSupervisorToldToStopExitsWithAStatusThatBringsItBack(t *testing.T) {
	held := supervisor(t, script("sleep 30"))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)

	go func() { done <- held.Run(ctx) }()

	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case status := <-done:
		if status != Interrupted {
			t.Fatalf("status %d", status)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the supervisor did not stop")
	}
}

func TestTheSupervisorPassesTheChildItsReleases(t *testing.T) {
	held := supervisor(t, nil)
	said := filepath.Join(held.State, "args")
	os.WriteFile(held.Self, script(fmt.Sprintf(`echo "$@" > %q; exit 4`, said)), 0o755)
	held.Args = []string{"--updates", "self"}

	if status := supervised(t, held); status != 4 {
		t.Fatalf("status %d", status)
	}

	args, _ := os.ReadFile(said)
	if strings.TrimSpace(string(args)) != "run --updates self --supervised --releases "+held.Releases {
		t.Fatalf("args %q", args)
	}
}

func TestANewReleaseThatConnectsBecomesTheGoodOne(t *testing.T) {
	held := supervisor(t, script("exit 9"))
	count := filepath.Join(held.State, "count")
	staged(t, held.Releases, "aaaaaaaaaaaaaaaa", connects(held.State, fmt.Sprintf(`if [ -f %q ]; then exit 5; fi
touch %q
exit 75`, count, count)))
	Point(held.Releases, Current, "aaaaaaaaaaaaaaaa")

	if status := supervised(t, held); status != 5 {
		t.Fatalf("status %d", status)
	}

	if Pointed(held.Releases, Good) != "aaaaaaaaaaaaaaaa" {
		t.Fatal("the release that connected is not the good one")
	}
}

func TestANewReleaseThatStopsIsRolledBack(t *testing.T) {
	held := supervisor(t, script("exit 7"))
	staged(t, held.Releases, "bbbbbbbbbbbbbbbb", script("exit 1"))
	Point(held.Releases, Current, "bbbbbbbbbbbbbbbb")

	if status := supervised(t, held); status != 7 {
		t.Fatalf("status %d", status)
	}

	if Pointed(held.Releases, Current) != "" {
		t.Fatal("the failed release is still current")
	}

	told := Result{}
	if err := Read(filepath.Join(held.State, ResultFile), &told); err != nil || told.OK || !strings.Contains(told.Error, "stopped before it connected") {
		t.Fatalf("result %+v: %v", told, err)
	}
}

func TestANewReleaseThatNeverConnectsIsRolledBackToTheGoodOne(t *testing.T) {
	held := supervisor(t, script("exit 8"))
	held.Probation = 300 * time.Millisecond
	staged(t, held.Releases, "cccccccccccccccc", script("exit 6"))
	staged(t, held.Releases, "dddddddddddddddd", script("exec sleep 30"))
	Point(held.Releases, Good, "cccccccccccccccc")
	Point(held.Releases, Current, "dddddddddddddddd")

	if status := supervised(t, held); status != 6 {
		t.Fatalf("status %d", status)
	}

	if Pointed(held.Releases, Current) != "cccccccccccccccc" {
		t.Fatalf("current is %q", Pointed(held.Releases, Current))
	}
}

func TestStagingPutsAVerifiedReleaseInPlace(t *testing.T) {
	fresh := script("echo 0.3.0")
	reader := []byte("reader")
	files := map[string][]byte{"xixo-link-darwin-arm64": fresh, MacReader: reader}
	listed(t, files, "0.3.0", 40, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, fresh), entry("mac/xixo-mac-reader", "darwin", "universal", release.RoleReader, reader))
	server, _ := served(t, files)
	root := t.TempDir()
	restarted := false

	staging := &Stager{
		Xixo: server.URL, Releases: filepath.Join(root, "releases"), State: root,
		Self: Self{Version: "0.2.0", SHA256: strings.Repeat("1", 64)}, Client: server.Client(),
		OS: "darwin", Arch: "arm64", Vouch: &Vouch{Unsigned: true, Xixo: server.URL, Client: server.Client()}, Restart: func() { restarted = true },
	}
	target := Target{Version: "0.3.0", SHA256: sum(fresh), MacReader: sum(reader)}

	if err := staging.Offer(context.Background(), target); err != nil {
		t.Fatal(err)
	}

	name := Pointed(staging.Releases, Current)
	if name != ReleaseName(target) || !restarted {
		t.Fatalf("current %q, restarted %v", name, restarted)
	}

	if held, _ := Digest(filepath.Join(staging.Releases, name, MacReader)); held != sum(reader) {
		t.Fatal("the mac reader is not beside the new release")
	}

	entries, _ := os.ReadDir(staging.Releases)
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".part-") {
			t.Fatalf("staging left %s behind", entry.Name())
		}
	}
}

func TestStagingWritesAChangedLaunchAgentAndRelaunchesInsteadOfRestarting(t *testing.T) {
	fresh := script("echo 0.3.0")
	plist := []byte("<plist>@HOME@/Library/Application Support/xixo-link/bin/xixo-link</plist>\n")
	files := map[string][]byte{"xixo-link-darwin-arm64": fresh, release.Plist: plist}
	listed(t, files, "0.3.0", 40, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, fresh), entry(release.Plist, "darwin", "", release.RolePlist, plist))
	server, _ := served(t, files)
	root := t.TempDir()
	agent := filepath.Join(root, "LaunchAgents", "network.xixo.link.plist")
	os.MkdirAll(filepath.Dir(agent), 0o700)
	os.WriteFile(agent, []byte("<plist>old</plist>\n"), 0o644)
	relaunched := false

	staging := &Stager{
		Xixo: server.URL, Releases: filepath.Join(root, "releases"), State: root,
		Self: Self{Version: "0.2.0", SHA256: strings.Repeat("1", 64)}, Client: server.Client(),
		OS: "darwin", Arch: "arm64", Vouch: &Vouch{Unsigned: true, Xixo: server.URL, Client: server.Client()},
		Restart: func() { t.Error("restarted when the launch agent changed") },
		Home:    "/Users/someone", Agent: agent, Relaunch: func(context.Context) error { relaunched = true; return nil },
	}

	if err := staging.Offer(context.Background(), Target{Version: "0.3.0", SHA256: sum(fresh)}); err != nil {
		t.Fatal(err)
	}

	held, _ := os.ReadFile(agent)
	if !relaunched || string(held) != "<plist>/Users/someone/Library/Application Support/xixo-link/bin/xixo-link</plist>\n" {
		t.Fatalf("relaunched %v, agent %q", relaunched, held)
	}

	relaunched = false
	staging.Restart = func() {}
	staging.Self = Self{Version: "0.3.0", SHA256: strings.Repeat("2", 64)}
	later := script("echo 0.3.1")
	files["xixo-link-darwin-arm64"] = later
	listed(t, files, "0.3.1", 41, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, later), entry(release.Plist, "darwin", "", release.RolePlist, plist))

	if err := staging.Offer(context.Background(), Target{Version: "0.3.1", SHA256: sum(later)}); err != nil {
		t.Fatal(err)
	}

	if relaunched {
		t.Fatal("relaunched when the launch agent had not changed")
	}
}

func TestStagingReplacesTheSupervisorOnlyWhenTheEpochRises(t *testing.T) {
	fresh := script("echo 0.3.0")
	files := map[string][]byte{"xixo-link-darwin-arm64": fresh}
	listed(t, files, "0.3.0", 40, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, fresh))
	server, _ := served(t, files)
	root := t.TempDir()
	supervisor := filepath.Join(root, "bin", "xixo-link")
	os.MkdirAll(filepath.Dir(supervisor), 0o700)
	os.WriteFile(supervisor, script("echo 0"), 0o755)
	relaunched := false

	staging := &Stager{
		Xixo: server.URL, Releases: filepath.Join(root, "releases"), State: root,
		Self: Self{Version: "0.2.0", SHA256: strings.Repeat("1", 64)}, Client: server.Client(),
		OS: "darwin", Arch: "arm64", Vouch: &Vouch{Unsigned: true, Xixo: server.URL, Client: server.Client()},
		Restart: func() {}, Supervisor: supervisor, Relaunch: func(context.Context) error { relaunched = true; return nil },
	}

	if err := staging.Offer(context.Background(), Target{Version: "0.3.0", SHA256: sum(fresh)}); err != nil {
		t.Fatal(err)
	}

	if held, _ := Digest(supervisor); relaunched || held == sum(fresh) {
		t.Fatal("the supervisor was replaced by a release with the same epoch")
	}

	staging.Self = Self{Version: "0.3.0", SHA256: strings.Repeat("2", 64)}
	later := script("echo 0.3.1")
	files["xixo-link-darwin-arm64"] = later
	raw := listedWithEpoch(t, files, "0.3.1", 41, 1, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, later))

	if err := staging.Offer(context.Background(), Target{Version: "0.3.1", SHA256: sum(later), Release: release.Sum(raw)}); err != nil {
		t.Fatal(err)
	}

	if held, _ := Digest(supervisor); !relaunched || held != sum(later) {
		t.Fatalf("relaunched %v, supervisor replaced %v", relaunched, held == sum(later))
	}
}

func TestStagingRefusesAMismatchedMacReader(t *testing.T) {
	fresh := script("echo 0.3.0")
	files := map[string][]byte{"xixo-link-darwin-arm64": fresh, MacReader: []byte("tampered")}
	listed(t, files, "0.3.0", 40, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, fresh), entry("mac/xixo-mac-reader", "darwin", "universal", release.RoleReader, []byte("tampered")))
	server, _ := served(t, files)
	root := t.TempDir()
	now := time.Now()

	staging := &Stager{
		Xixo: server.URL, Releases: filepath.Join(root, "releases"), State: root,
		Self: Self{Version: "0.2.0", SHA256: strings.Repeat("1", 64)}, Client: server.Client(),
		OS: "darwin", Arch: "arm64", Vouch: &Vouch{Unsigned: true, Xixo: server.URL, Client: server.Client()}, Restart: func() { t.Error("restarted after a failed update") },
		Now: func() time.Time { return now },
	}

	err := staging.Offer(context.Background(), Target{Version: "0.3.0", SHA256: sum(fresh), MacReader: strings.Repeat("7", 64)})
	if err == nil || !strings.Contains(err.Error(), "mac reader") {
		t.Fatalf("offer: %v", err)
	}

	if Pointed(staging.Releases, Current) != "" {
		t.Fatal("a failed update became current")
	}

	now = now.Add(InFlight + time.Minute)

	warned := staging.Warnings()
	if len(warned) != 1 || !strings.Contains(warned[0], "mac reader") {
		t.Fatalf("warnings %v", warned)
	}
}

func TestAReleaseIsGoodAsSoonAsItConnects(t *testing.T) {
	held := supervisor(t, script("exit 9"))
	good := filepath.Join(held.Releases, Good)
	staged(t, held.Releases, "eeeeeeeeeeeeeeee", connects(held.State, fmt.Sprintf(`i=0
while [ "$i" -lt 200 ]; do
  [ "$(readlink %q)" = eeeeeeeeeeeeeeee ] && exit 5
  i=$((i + 1))
  sleep 0.01
done
exit 6`, good)))
	Point(held.Releases, Current, "eeeeeeeeeeeeeeee")
	Write(filepath.Join(held.Releases, "eeeeeeeeeeeeeeee", FloorFile), int64(40), 0o600)

	if status := supervised(t, held); status != 5 {
		t.Fatalf("the release was not good while it ran: status %d", status)
	}

	if floor, err := Floor(FloorFor(held.Releases)); err != nil || floor != 40 {
		t.Fatalf("the serial of the release that connected was not kept: %d %v", floor, err)
	}
}

func TestStagingKeepsTheReleaseItRunsFrom(t *testing.T) {
	fresh := script("echo 0.3.0")
	files := map[string][]byte{"xixo-link-darwin-arm64": fresh}
	listed(t, files, "0.3.0", 40, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, fresh))
	server, _ := served(t, files)
	root := t.TempDir()
	releases := filepath.Join(root, "releases")
	staged(t, releases, "ffffffffffffffff", script("exit 0"))
	Point(releases, Current, "ffffffffffffffff")

	staging := &Stager{
		Xixo: server.URL, Releases: releases, State: root,
		Self: Self{Version: "0.2.0", SHA256: strings.Repeat("1", 64)}, Client: server.Client(),
		OS: "darwin", Arch: "arm64", Vouch: &Vouch{Unsigned: true, Xixo: server.URL, Client: server.Client()}, Restart: func() {},
	}

	if err := staging.Offer(context.Background(), Target{Version: "0.3.0", SHA256: sum(fresh)}); err != nil {
		t.Fatal(err)
	}

	if !regular(filepath.Join(releases, "ffffffffffffffff", Binary)) {
		t.Fatal("staging removed the release xixo link runs from before the new one connected")
	}
}

func TestStagingGoesBackToAReleaseItHoldsAndReportsWhatItHolds(t *testing.T) {
	old, fresh := script("echo 0.2.0"), script("echo 0.3.0")
	root := t.TempDir()
	releases := filepath.Join(root, "releases")
	restarted := 0

	for serial, body := range map[int64][]byte{20: old, 30: fresh} {
		files := map[string][]byte{}
		raw := listedWithEpoch(t, files, "0."+strconv.FormatInt(serial/10, 10)+".0", serial, 0, entry("xixo-link-darwin-arm64", "darwin", "arm64", release.RoleBinary, body))
		dir := filepath.Join(releases, ReleaseName(Target{SHA256: sum(body)}))
		os.MkdirAll(dir, 0o700)
		os.WriteFile(filepath.Join(dir, Binary), body, 0o755)
		os.WriteFile(filepath.Join(dir, release.File), raw, 0o600)
	}

	Point(releases, Current, ReleaseName(Target{SHA256: sum(fresh)}))
	Point(releases, Good, ReleaseName(Target{SHA256: sum(fresh)}))
	Write(filepath.Join(root, ResultFile), Result{Version: "0.3.0", SHA256: sum(fresh), OK: true}, 0o600)

	staging := &Stager{
		Releases: releases, State: root, Self: Self{Version: "0.3.0", SHA256: sum(fresh)},
		OS: "darwin", Arch: "arm64", Restart: func() { restarted++ },
	}

	report := staging.Report()
	if report.Result == nil || !report.Result.OK || len(report.Held) != 2 || report.Held[0].Serial != 30 || report.Held[1].Version != "0.2.0" || report.Held[1].SHA256 != sum(old) {
		t.Fatalf("report %+v %+v", report.Result, report.Held)
	}

	if err := staging.RollBack(context.Background(), Target{Version: "0.2.0", SHA256: sum(old)}); err != nil {
		t.Fatal(err)
	}

	if Pointed(releases, Current) != ReleaseName(Target{SHA256: sum(old)}) || restarted != 1 {
		t.Fatalf("current %q, restarted %d", Pointed(releases, Current), restarted)
	}

	if err := staging.RollBack(context.Background(), Target{Version: "0.2.0", SHA256: sum(old)}); err != nil || restarted != 1 {
		t.Fatalf("the same request restarted again: %v %d", err, restarted)
	}

	staging.Self = Self{Version: "0.2.0", SHA256: sum(old)}
	err := staging.RollBack(context.Background(), Target{Version: "0.1.0", SHA256: strings.Repeat("c", 64)})
	if err == nil || !strings.Contains(err.Error(), "does not hold") {
		t.Fatalf("a release this Mac lacks gave %v", err)
	}
}
