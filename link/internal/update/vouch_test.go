package update

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/verify"
)

const commit = "c589ffe682d3497df159d3615be691387ebea7d9"

func signedFiles(t *testing.T, files map[string][]byte, serial int64, entries ...release.Entry) Target {
	t.Helper()
	held := release.Release{Version: "0.3.0+c589ffe", Serial: serial, Revision: commit, Channel: "main", Files: entries}
	raw, err := json.Marshal(held)
	if err != nil {
		t.Fatal(err)
	}

	files[release.File] = raw
	files[release.Bundle] = []byte("signed")

	return Target{Version: held.Version, Release: release.Sum(raw), Serial: serial}
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

func TestTheUpdaterInstallsOnlyABuildTheSignedReleaseListsAndRaisesItsFloor(t *testing.T) {
	fresh := script("echo 0.3.0+c589ffe")
	files := map[string][]byte{"xixo-link-linux-amd64": fresh}
	target := signedFiles(t, files, 40, entry("xixo-link-linux-amd64", "linux", "amd64", release.RoleBinary, fresh))
	target.SHA256 = sum(fresh)
	server, _ := served(t, files)

	updater, binary, _ := applying(t, fresh, true)
	updater.Xixo = server.URL
	updater.Client = server.Client()
	updater.Vouch = vouching(t, server.URL)
	updater.Vouch.Client = server.Client()
	Write(filepath.Join(updater.Requests, RequestFile), Request{Target: target, From: "0.2.0"}, 0o644)

	if err := updater.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}

	if held, _ := Digest(binary); held != sum(fresh) {
		t.Fatal("the signed build is not in place")
	}

	raw, _ := os.ReadFile(updater.Vouch.Floor)
	if strings.TrimSpace(string(raw)) != "40" {
		t.Fatalf("floor %q", raw)
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

func TestTheSameSerialIsAcceptedAgainAndAnUnsignedDevMachineSkipsTheCheck(t *testing.T) {
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

	unsigned := &Vouch{Unsigned: true}
	if _, err := unsigned.Release(context.Background(), Target{Version: "0.3.0", SHA256: sum(fresh)}, "linux", "amd64"); err != nil {
		t.Fatal(err)
	}
}

func TestAnUpdaterWithNoWayToCheckSignaturesInstallsNothing(t *testing.T) {
	fresh := script("echo 0.3.0")
	updater, binary, _ := applying(t, fresh, true)
	updater.Vouch = nil

	if err := updater.Apply(context.Background()); !errors.Is(err, ErrUnsignedOffer) {
		t.Fatalf("err %v", err)
	}

	if held, _ := Digest(binary); held == sum(fresh) {
		t.Fatal("an unchecked build was installed")
	}
}
