package update

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
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
