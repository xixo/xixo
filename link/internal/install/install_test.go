package install

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/update"
)

const (
	template = "[Service]\nUser=@USER@\n@FOLDERS@\nExecStart=x\n"
	commit   = "c589ffe682d3497df159d3615be691387ebea7d9"
)

func serving(t *testing.T, files map[string]string) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := files[strings.TrimPrefix(r.URL.Path, "/link/download/")]
		if !ok {
			http.NotFound(w, r)

			return
		}

		w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)

	return server
}

func recorder() (*[]string, func(context.Context, string, ...string) error) {
	ran := &[]string{}

	return ran, func(_ context.Context, name string, args ...string) error {
		*ran = append(*ran, name+" "+strings.Join(args, " "))

		return nil
	}
}

func lookups(known map[string][2]int) func(string) (int, int, error) {
	return func(name string) (int, int, error) {
		if held, ok := known[name]; ok {
			return held[0], held[1], nil
		}

		return 0, 0, errors.New("unknown user " + name)
	}
}

func sum(body string) string {
	hashed := sha256.Sum256([]byte(body))

	return hex.EncodeToString(hashed[:])
}

func entry(name, role, body string) release.Entry {
	held := release.Entry{Name: name, Role: role, SHA256: sum(body), Size: int64(len(body))}
	if role == release.RoleBinary {
		held.OS, held.Arch = "linux", "amd64"
	}

	return held
}

func released(t *testing.T, build string) (map[string]string, string) {
	t.Helper()
	files := map[string]string{
		"xixo-link-linux-amd64": build, Service: template, update.FetchUnit: "fetch", update.UpdateUnit: "update", update.UpdatePath: "path",
		update.UpdateTimer: "timer", update.PackagesUnit: "packages", update.PartUnit: "part unit", update.PartPath: "part path",
	}

	entries := []release.Entry{entry("xixo-link-linux-amd64", release.RoleBinary, build)}
	for name, body := range files {
		if release.UnitName.MatchString(name) {
			entries = append(entries, entry(name, release.RoleUnit, body))
		}
	}

	held := release.Release{Version: "0.3.0", Serial: 20, Revision: commit, Channel: "releases", PackagesApt: []string{"poppler-utils", "ffmpeg"}, Files: entries}
	raw, err := json.Marshal(held)
	if err != nil {
		t.Fatal(err)
	}

	files[release.File] = string(raw)

	return files, release.ID(raw)
}

func installing(t *testing.T, build string) (*Installer, string, *[]string) {
	t.Helper()
	root := t.TempDir()
	from := filepath.Join(t.TempDir(), "xixo-link")
	os.WriteFile(from, []byte(build), 0o755)
	files, id := released(t, "the build")
	server := serving(t, files)
	ran, run := recorder()

	return &Installer{
		Root: root, Xixo: server.URL, Issuer: "https://id.example", User: "jon", From: from, Arch: "amd64", Unsigned: true,
		Client: server.Client(), Run: run, LookPath: func(string) (string, error) { return "/usr/bin/apt-get", nil },
		Lookup: lookups(map[string][2]int{"jon": {1000, 1000}, Updater: {999, 999}, PartUser: {998, 998}}),
	}, id, ran
}

func TestLinuxInstallKeepsTheReleaseRendersItsUnitsAndInstallsItsPackages(t *testing.T) {
	held, id, ran := installing(t, "the build")
	media := filepath.Join(t.TempDir(), "media")
	inbox := filepath.Join(t.TempDir(), "inbox")
	os.Mkdir(media, 0o755)
	os.Mkdir(inbox, 0o755)
	held.Folders = []string{media, inbox + ":rw"}
	calls := 0
	held.Lookup = func(name string) (int, int, error) {
		calls++
		if name == PartUser && calls <= 2 {
			return 0, 0, errors.New("unknown user " + name)
		}

		return lookups(map[string][2]int{"jon": {1000, 1000}, Updater: {999, 999}, PartUser: {998, 998}})(name)
	}
	layout := update.Layout{Root: held.Root}
	os.MkdirAll(layout.Lib(), 0o755)
	os.WriteFile(layout.Binary(), []byte("the old build, a plain file"), 0o755)
	os.WriteFile(layout.Binary()+update.Previous, []byte("older"), 0o755)

	if err := held.Linux(context.Background()); err != nil {
		t.Fatal(err)
	}

	if read, _ := os.ReadFile(filepath.Join(layout.Release(id), update.Binary)); string(read) != "the build" {
		t.Fatalf("the release holds %q", read)
	}

	if _, err := os.Stat(filepath.Join(layout.Release(id), release.File)); err != nil {
		t.Fatal("the release has no release.json beside it")
	}

	if linked, _ := os.Readlink(layout.Binary()); linked != "releases/current/xixo-link" {
		t.Fatalf("the binary links to %q", linked)
	}

	if _, err := os.Lstat(layout.Binary() + update.Previous); err == nil {
		t.Fatal("the old updater's previous binary stayed")
	}

	if linked, _ := os.Readlink(layout.Bin()); linked != Lib+"/xixo-link" {
		t.Fatalf("the command links to %q", linked)
	}

	if layout.Pointed(update.Current) != id || layout.Pointed(update.Good) != id {
		t.Fatalf("current %q good %q", layout.Pointed(update.Current), layout.Pointed(update.Good))
	}

	config, _ := os.ReadFile(layout.Config())
	if !strings.Contains(string(config), held.Xixo) || !strings.Contains(string(config), `"writable": true`) || !strings.Contains(string(config), `"releases": "unsigned"`) {
		t.Fatalf("config %s", config)
	}

	if user, err := layout.User(); err != nil || user != "jon" {
		t.Fatalf("install.json names %q: %v", user, err)
	}

	unit, _ := os.ReadFile(filepath.Join(layout.Units(), Service))
	if !strings.Contains(string(unit), "User=jon\n") || !strings.Contains(string(unit), "BindReadOnlyPaths=\"-"+media+"\"") || !strings.Contains(string(unit), "BindPaths=\"-"+inbox+"\"") {
		t.Fatalf("unit %s", unit)
	}

	for name, body := range map[string]string{update.FetchUnit: "fetch", update.UpdateUnit: "update", update.UpdatePath: "path", update.UpdateTimer: "timer", update.PackagesUnit: "packages", update.PartUnit: "part unit", update.PartPath: "part path"} {
		if read, _ := os.ReadFile(filepath.Join(layout.Units(), name)); string(read) != body {
			t.Fatalf("%s holds %q", name, read)
		}
	}

	if floor, _ := update.Floor(layout.Floor()); floor != 20 {
		t.Fatalf("floor %d", floor)
	}

	if info, err := os.Stat(filepath.Join(held.Root, StateDir)); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("state dir %v %v", info, err)
	}

	want := []string{
		"useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xixo-link-part",
		"userdel xixo-link-update",
		"systemctl daemon-reload",
		"systemctl enable --quiet xixo-link",
		"systemctl enable --now --quiet xixo-link-update.path xixo-link-update.timer",
		"systemctl enable --now --quiet xixo-link-part@models.path",
		"env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -q update",
		"env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get -q install -y --no-install-recommends -- poppler-utils ffmpeg",
	}

	if strings.Join(*ran, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran:\n%s", strings.Join(*ran, "\n"))
	}

	if (&update.Packages{Layout: layout}).Changed() {
		t.Fatal("the packages installed were not recorded")
	}

	if err := held.StartLinux(context.Background()); err != nil || (*ran)[len(*ran)-1] != "systemctl restart xixo-link" {
		t.Fatalf("start: %v %v", err, *ran)
	}
}

func TestLinuxInstallAgainMakesNoAccountsAndUninstallRemovesEverything(t *testing.T) {
	held, _, ran := installing(t, "the build")
	held.Lookup = lookups(map[string][2]int{"jon": {1000, 1000}, PartUser: {998, 998}})

	if err := held.Linux(context.Background()); err != nil {
		t.Fatal(err)
	}

	for _, line := range *ran {
		if strings.HasPrefix(line, "useradd") || strings.HasPrefix(line, "userdel") {
			t.Fatalf("ran %q", line)
		}
	}

	if err := held.UninstallLinux(context.Background()); err != nil {
		t.Fatal(err)
	}

	layout := update.Layout{Root: held.Root}
	if _, err := os.Stat(layout.Lib()); err == nil {
		t.Fatal("the lib dir stayed")
	}

	if entries, _ := os.ReadDir(layout.Units()); len(entries) != 0 {
		t.Fatalf("units stayed: %v", entries)
	}

	disabled := (*ran)[len(*ran)-2]
	for _, unit := range []string{"xixo-link ", update.UpdatePath, update.UpdateTimer, update.FetchUnit, update.UpdateUnit, update.PackagesUnit, "xixo-link-part@models.path"} {
		if !strings.Contains(disabled, unit) {
			t.Fatalf("uninstall did not disable %s: %q", unit, disabled)
		}
	}
}

func TestInstallNeedsABuildTheReleaseListsAndAnAccount(t *testing.T) {
	if err := (&Installer{Root: t.TempDir()}).Linux(context.Background()); !errors.Is(err, ErrNoFrom) {
		t.Fatalf("got %v", err)
	}

	held, _, _ := installing(t, "the build")
	held.User = "nobody-here"

	if err := held.Linux(context.Background()); err == nil || !strings.Contains(err.Error(), "not an account on this machine") {
		t.Fatalf("got %v", err)
	}

	other, _, _ := installing(t, "another build")

	if err := other.Linux(context.Background()); !errors.Is(err, ErrNotListed) {
		t.Fatalf("a build the release does not list installed: %v", err)
	}

	if _, err := os.Stat(update.Layout{Root: other.Root}.Releases()); err == nil {
		t.Fatal("a build the release does not list was kept")
	}
}

func TestMacInstallWritesTheAgentForThisHomeAndKeepsTheReader(t *testing.T) {
	home := t.TempDir()
	work := t.TempDir()
	build := filepath.Join(work, "xixo-link")
	os.WriteFile(build, []byte("the build"), 0o755)
	server := serving(t, map[string]string{Plist: "<string>@HOME@/Library/Application Support/xixo-link/bin/xixo-link</string>", MacReader: "the reader"})
	ran, run := recorder()
	held := &Installer{Home: home, Xixo: server.URL, Issuer: "https://id.example", From: build, Client: server.Client(), Run: run}

	if err := held.Mac(context.Background()); err != nil {
		t.Fatal(err)
	}

	support := filepath.Join(home, "Library", "Application Support", "xixo-link")
	if read, _ := os.ReadFile(filepath.Join(support, "bin", "xixo-link")); string(read) != "the build" {
		t.Fatalf("bin holds %q", read)
	}

	if read, _ := os.ReadFile(filepath.Join(support, "bin", MacReader)); string(read) != "the reader" {
		t.Fatalf("reader holds %q", read)
	}

	agent, _ := os.ReadFile(filepath.Join(home, "Library", "LaunchAgents", LaunchLabel+".plist"))
	if !strings.Contains(string(agent), home+"/Library/Application Support/xixo-link/bin/xixo-link") || strings.Contains(string(agent), "@HOME@") {
		t.Fatalf("agent %s", agent)
	}

	if _, err := os.Stat(filepath.Join(support, "config.json")); err != nil {
		t.Fatal(err)
	}

	if len(*ran) != 0 {
		t.Fatalf("install ran %v", *ran)
	}

	if err := held.UninstallMac(context.Background()); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(support); err == nil {
		t.Fatal("the support dir stayed")
	}
}
