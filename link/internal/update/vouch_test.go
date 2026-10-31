package update

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/verify"
)

const commit = "c589ffe682d3497df159d3615be691387ebea7d9"

func listed(t *testing.T, files map[string][]byte, version string, serial int64, entries ...release.Entry) (Target, []byte) {
	t.Helper()
	raw := listedWithEpoch(t, files, version, serial, 0, entries...)

	return Target{Version: version, Release: release.Sum(raw)}, raw
}

func listedWithEpoch(t *testing.T, files map[string][]byte, version string, serial, epoch int64, entries ...release.Entry) []byte {
	t.Helper()
	held := release.Release{Version: version, Serial: serial, Revision: commit, Channel: release.Channel(version), SupervisorEpoch: epoch, PackagesApt: release.Packages, Files: entries}
	raw, err := json.Marshal(held)
	if err != nil {
		t.Fatal(err)
	}

	files[release.File] = raw

	return raw
}

func signedFiles(t *testing.T, files map[string][]byte, serial int64, entries ...release.Entry) Target {
	t.Helper()
	target, _ := listed(t, files, "0.3.0+c589ffe", serial, entries...)
	files[release.Bundle] = []byte("signed")

	return target
}

func entry(name, goos, goarch, role string, body []byte) release.Entry {
	return release.Entry{Name: name, OS: goos, Arch: goarch, Role: role, SHA256: sum(body), Size: int64(len(body))}
}

func vouching(t *testing.T, xixo string) *Vouch {
	t.Helper()

	return &Vouch{
		Xixo: xixo, Floor: filepath.Join(t.TempDir(), FloorFile),
		Verified: func(bundle, raw []byte) (release.Release, error) {
			if string(bundle) != "signed" {
				return release.Release{}, verify.ErrUnsigned
			}

			return release.Parse(raw)
		},
	}
}

func TestTheUpdaterInstallsOnlyAReleaseWhoseSignatureChecksOutAndRaisesItsFloor(t *testing.T) {
	held := machine(t)
	fresh := script("echo 0.3.0+c589ffe")
	updater := held.updater(true)
	updater.Vouch = vouching(t, "")
	updater.Vouch.Floor = held.layout.Floor()

	id := held.stage(t, fresh, "0.3.0+c589ffe", 40, nil, []byte("signed"))

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held.layout.Pointed(Current) != id {
		t.Fatal("the signed release is not current")
	}

	if floor, _ := Floor(held.layout.Floor()); floor != 40 {
		t.Fatalf("floor %d", floor)
	}

	forged := held.stage(t, script("echo 0.3.1+c589ffe"), "0.3.1+c589ffe", 41, nil, []byte("forged"))

	if err := updater.Apply(context.Background()); !errors.Is(err, verify.ErrUnsigned) {
		t.Fatalf("a forged bundle gave %v", err)
	}

	if held.layout.Pointed(Current) != id || regular(filepath.Join(held.layout.Release(forged), Binary)) {
		t.Fatal("a release with a forged signature was kept")
	}
}

func TestABuildIsRefusedWithoutASignedReleaseThatListsIt(t *testing.T) {
	fresh := script("echo 0.3.0+c589ffe")
	other := script("echo something else")
	ctx := context.Background()

	cases := map[string]func(files map[string][]byte, target *Target, vouch *Vouch){
		"no release named": func(_ map[string][]byte, target *Target, _ *Vouch) { target.Release = "" },
		"another release": func(files map[string][]byte, _ *Target, _ *Vouch) {
			files[release.File] = append(files[release.File], ' ')
		},
		"no signature":    func(files map[string][]byte, _ *Target, _ *Vouch) { files[release.Bundle] = []byte("forged") },
		"another build":   func(_ map[string][]byte, target *Target, _ *Vouch) { target.SHA256 = sum(other) },
		"another version": func(_ map[string][]byte, target *Target, _ *Vouch) { target.Version = "0.3.0" },
		"an older serial": func(_ map[string][]byte, _ *Target, vouch *Vouch) { os.WriteFile(vouch.Floor, []byte("41\n"), 0o644) },
		"another reader":  func(_ map[string][]byte, target *Target, _ *Vouch) { target.MacReader = sum(other) },
	}

	for name, change := range cases {
		files := map[string][]byte{}
		target := signedFiles(t, files, 40, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh))
		target.SHA256 = sum(fresh)
		server, _ := served(t, files)
		vouch := vouching(t, server.URL)
		vouch.Client = server.Client()

		change(files, &target, vouch)

		if _, err := vouch.Release(ctx, target, "linux", "amd64"); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestTheSameSerialIsAcceptedAgainAndAnUnsignedDevMachineChecksOnlyTheList(t *testing.T) {
	fresh := script("echo 0.3.0+c589ffe")
	files := map[string][]byte{}
	target := signedFiles(t, files, 40, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh))
	target.SHA256 = sum(fresh)
	server, _ := served(t, files)
	vouch := vouching(t, server.URL)
	vouch.Client = server.Client()
	os.WriteFile(vouch.Floor, []byte("40\n"), 0o644)

	if _, err := vouch.Release(context.Background(), target, "linux", "amd64"); err != nil {
		t.Fatal(err)
	}

	plain := map[string][]byte{}
	listed(t, plain, "0.3.0", 40, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh))
	dev, _ := served(t, plain)
	unsigned := &Vouch{Unsigned: true, Xixo: dev.URL, Client: dev.Client(), Floor: filepath.Join(t.TempDir(), FloorFile)}

	if _, err := unsigned.Release(context.Background(), Target{Version: "0.3.0", SHA256: sum(fresh)}, "linux", "amd64"); err != nil {
		t.Fatal(err)
	}

	if _, err := unsigned.Release(context.Background(), Target{Version: "0.3.0", SHA256: sum(script("echo other"))}, "linux", "amd64"); !errors.Is(err, ErrNotInRelease) {
		t.Fatalf("an unsigned dev machine took a build the release does not list: %v", err)
	}
}

func TestAnUpdaterWithNoWayToCheckSignaturesInstallsNothing(t *testing.T) {
	held := machine(t)
	id := held.stage(t, script("echo 0.3.0"), "0.3.0", 20, nil, nil)
	updater := held.updater(true)
	updater.Vouch = nil

	if err := updater.Apply(context.Background()); !errors.Is(err, ErrUnsignedOffer) {
		t.Fatalf("err %v", err)
	}

	if held.layout.Pointed(Current) == id {
		t.Fatal("an unchecked release was installed")
	}
}

func TestTheRunningBuildsOwnSerialIsTheLowestItAccepts(t *testing.T) {
	fresh := script("echo 0.3.0+c589ffe")
	files := map[string][]byte{}
	target := signedFiles(t, files, 40, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh))
	target.SHA256 = sum(fresh)
	server, _ := served(t, files)
	vouch := vouching(t, server.URL)
	vouch.Client = server.Client()
	vouch.Running = 41

	if _, err := vouch.Release(context.Background(), target, "linux", "amd64"); !errors.Is(err, ErrOlderRelease) {
		t.Fatalf("a machine with no floor file took an older release than it runs: %v", err)
	}
}

func TestAFloorThatCannotBeReadInstallsNothing(t *testing.T) {
	fresh := script("echo 0.3.0+c589ffe")
	files := map[string][]byte{}
	target := signedFiles(t, files, 40, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh))
	target.SHA256 = sum(fresh)
	server, _ := served(t, files)
	vouch := vouching(t, server.URL)
	vouch.Client = server.Client()
	os.WriteFile(vouch.Floor, []byte("forty\n"), 0o644)

	if _, err := vouch.Release(context.Background(), target, "linux", "amd64"); err == nil {
		t.Fatal("a damaged floor let a release through")
	}

	os.Remove(vouch.Floor)
	os.Symlink(filepath.Join(t.TempDir(), "elsewhere"), vouch.Floor)
	if _, err := vouch.Release(context.Background(), target, "linux", "amd64"); err == nil {
		t.Fatal("a floor that is a link let a release through")
	}
}

func TestTheFloorOnlyRises(t *testing.T) {
	path := filepath.Join(t.TempDir(), FloorFile)

	for _, serial := range []int64{40, 12, 41} {
		if err := Raise(path, serial); err != nil {
			t.Fatal(err)
		}
	}

	if held, err := Floor(path); err != nil || held != 41 {
		t.Fatalf("floor %d err %v", held, err)
	}
}
