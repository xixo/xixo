package install

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
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

func TestLinuxInstallWritesTheBinaryTheConfigurationAndEveryUnit(t *testing.T) {
	root := t.TempDir()
	build := filepath.Join(t.TempDir(), "xixo-link")
	os.WriteFile(build, []byte("the build"), 0o755)
	media := filepath.Join(t.TempDir(), "media")
	inbox := filepath.Join(t.TempDir(), "inbox")
	os.Mkdir(media, 0o755)
	os.Mkdir(inbox, 0o755)

	server := serving(t, map[string]string{
		Service: "[Service]\nUser=@USER@\n@FOLDERS@\nExecStart=x\n", UpdateUnit: "update unit", UpdatePath: "update path",
		PartUnit: "part unit", PartPath: "part path",
	})
	ran, run := recorder()
	held := &Installer{
		Root: root, Xixo: server.URL, Issuer: "https://id.example", User: "jon", From: build, Folders: []string{media, inbox + ":rw"},
		Client: server.Client(), Run: run,
	}
	held.Lookup = func(name string) (int, int, error) {
		if (name == Updater || name == PartUser) && len(*ran) < 2 {
			return 0, 0, errors.New("unknown user " + name)
		}

		return lookups(map[string][2]int{"jon": {1000, 1000}, Updater: {999, 999}, PartUser: {998, 998}})(name)
	}

	if err := held.Linux(context.Background()); err != nil {
		t.Fatal(err)
	}

	if read, _ := os.ReadFile(filepath.Join(root, Lib, "xixo-link")); string(read) != "the build" {
		t.Fatalf("the binary holds %q", read)
	}

	if linked, _ := os.Readlink(filepath.Join(root, Bin)); linked != Lib+"/xixo-link" {
		t.Fatalf("the link points at %q", linked)
	}

	config, _ := os.ReadFile(filepath.Join(root, Etc, "config.json"))
	if !strings.Contains(string(config), server.URL) || !strings.Contains(string(config), `"writable": true`) {
		t.Fatalf("config %s", config)
	}

	unit, _ := os.ReadFile(filepath.Join(root, Units, Service))
	if !strings.Contains(string(unit), "User=jon\n") || !strings.Contains(string(unit), "BindReadOnlyPaths=\"-"+media+"\"") || !strings.Contains(string(unit), "BindPaths=\"-"+inbox+"\"") {
		t.Fatalf("unit %s", unit)
	}

	for name, body := range map[string]string{UpdateUnit: "update unit", UpdatePath: "update path", PartUnit: "part unit", PartPath: "part path"} {
		if read, _ := os.ReadFile(filepath.Join(root, Units, name)); string(read) != body {
			t.Fatalf("%s holds %q", name, read)
		}
	}

	if info, err := os.Stat(filepath.Join(root, StateDir)); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("state dir %v %v", info, err)
	}

	want := []string{
		"useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xixo-link-update",
		"useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xixo-link-part",
		"systemctl daemon-reload",
		"systemctl enable --quiet xixo-link",
		"systemctl enable --now --quiet xixo-link-update.path",
		"systemctl enable --now --quiet xixo-link-part@models.path",
	}

	if strings.Join(*ran, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran:\n%s", strings.Join(*ran, "\n"))
	}

	if err := held.StartLinux(context.Background()); err != nil || (*ran)[len(*ran)-1] != "systemctl restart xixo-link" {
		t.Fatalf("start: %v %v", err, *ran)
	}
}

func TestLinuxInstallKeepsTheUpdaterAccountAndSkipsPartsAnOlderXixoDoesNotServe(t *testing.T) {
	root := t.TempDir()
	build := filepath.Join(t.TempDir(), "xixo-link")
	os.WriteFile(build, []byte("the build"), 0o755)
	server := serving(t, map[string]string{Service: "User=@USER@\n@FOLDERS@\n", UpdateUnit: "u", UpdatePath: "p"})
	ran, run := recorder()
	held := &Installer{
		Root: root, Xixo: server.URL, Issuer: "https://id.example", User: "jon", From: build,
		Client: server.Client(), Run: run, Lookup: lookups(map[string][2]int{"jon": {1000, 1000}, Updater: {999, 999}, PartUser: {998, 998}}),
	}

	if err := held.Linux(context.Background()); err != nil {
		t.Fatal(err)
	}

	for _, line := range *ran {
		if strings.HasPrefix(line, "useradd") || strings.Contains(line, "xixo-link-part@") {
			t.Fatalf("ran %q", line)
		}
	}

	if _, err := os.Stat(filepath.Join(root, Units, PartUnit)); err == nil {
		t.Fatal("a part unit was written without a template")
	}

	if err := held.UninstallLinux(context.Background()); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(root, Lib)); err == nil {
		t.Fatal("the lib dir stayed")
	}

	if last := (*ran)[len(*ran)-2]; !strings.HasPrefix(last, "systemctl disable --now --quiet xixo-link xixo-link-update.path") {
		t.Fatalf("uninstall ran %q", last)
	}
}

func TestInstallNeedsABuildAndAnAccount(t *testing.T) {
	if err := (&Installer{Root: t.TempDir()}).Linux(context.Background()); !errors.Is(err, ErrNoFrom) {
		t.Fatalf("got %v", err)
	}

	build := filepath.Join(t.TempDir(), "xixo-link")
	os.WriteFile(build, []byte("b"), 0o755)
	server := serving(t, map[string]string{Service: "User=@USER@\n@FOLDERS@\n", UpdateUnit: "u", UpdatePath: "p"})
	_, run := recorder()
	held := &Installer{Root: t.TempDir(), Xixo: server.URL, Issuer: "https://id.example", User: "nobody-here", From: build,
		Client: server.Client(), Run: run, Lookup: lookups(map[string][2]int{Updater: {999, 999}, PartUser: {998, 998}})}

	if err := held.Linux(context.Background()); err == nil || !strings.Contains(err.Error(), "not an account on this machine") {
		t.Fatalf("got %v", err)
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
