package release

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const revision = "c589ffe682d3497df159d3615be691387ebea7d9"

func built(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	for name, body := range map[string]string{
		"xixo-link-linux-amd64":  "linux amd64",
		"xixo-link-darwin-arm64": "darwin arm64",
		"xixo-link.service":      "[Unit]",
		"xixo-link-part@.path":   "[Path]",
		"xixo-link.plist":        "<plist/>",
		"version":                "0.2.0+c589ffe",
		"notes.txt":              "not part of a release",
		MacDir + "/" + MacReader: "reader",
	} {
		path := filepath.Join(dir, filepath.FromSlash(name))
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	return dir
}

func TestABuildFolderIsDescribedWithEachFilesRoleAndDigest(t *testing.T) {
	held, err := Describe(built(t), "0.2.0+c589ffe", revision, 1234)
	if err != nil {
		t.Fatal(err)
	}

	names := []string{}
	for _, entry := range held.Files {
		names = append(names, entry.Name+":"+entry.Role)
	}

	if strings.Join(names, " ") != "mac/xixo-mac-reader:mac_reader xixo-link-darwin-arm64:binary xixo-link-linux-amd64:binary xixo-link-part@.path:unit xixo-link.plist:plist xixo-link.service:unit" {
		t.Fatalf("files %v", names)
	}

	build, found := held.Build("linux", "amd64")
	if !found || build.SHA256 != Sum([]byte("linux amd64")) || build.Size != 11 {
		t.Fatalf("build %+v", build)
	}

	if _, found := held.Build("linux", "arm64"); found {
		t.Fatal("a build that is not there was found")
	}

	raw, _ := json.Marshal(held)
	if parsed, err := Parse(raw); err != nil || parsed.Serial != 1234 {
		t.Fatalf("parsed %+v err %v", parsed, err)
	}
}

func TestAReleaseThatNamesAnythingOddIsRefused(t *testing.T) {
	good, _ := Describe(built(t), "0.2.0+c589ffe", revision, 1234)

	for name, change := range map[string]func(*Release){
		"version":   func(r *Release) { r.Version = "latest" },
		"serial":    func(r *Release) { r.Serial = 0 },
		"revision":  func(r *Release) { r.Revision = "main" },
		"channel":   func(r *Release) { r.Channel = "nightly" },
		"empty":     func(r *Release) { r.Files = nil },
		"path":      func(r *Release) { r.Files[1].Name = "../../usr/local/bin/xixo-link-darwin-arm64" },
		"platform":  func(r *Release) { r.Files[1].OS = "linux" },
		"role":      func(r *Release) { r.Files[0].Role = "script" },
		"digest":    func(r *Release) { r.Files[0].SHA256 = "abc" },
		"unit name": func(r *Release) { r.Files[3].Name = "sshd.service" },
	} {
		copied := good
		copied.Files = append([]Entry{}, good.Files...)
		change(&copied)
		raw, _ := json.Marshal(copied)

		if _, err := Parse(raw); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}

func TestAMainBuildIsOnMainAndAReleaseIsOnReleases(t *testing.T) {
	if Channel("0.2.0+c589ffe") != "main" || Channel("0.3.0") != "releases" {
		t.Fatal("wrong channel")
	}
}
