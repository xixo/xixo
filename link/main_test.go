package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestCommands(t *testing.T) {
	out := &bytes.Buffer{}

	if err := command(context.Background(), []string{"version"}, nil, out); err != nil || strings.TrimSpace(out.String()) != "dev" {
		t.Fatalf("version printed %q, %v", out, err)
	}

	if err := command(context.Background(), []string{"launch"}, nil, out); err == nil {
		t.Fatal("an unknown command ran")
	}

	out.Reset()
	if err := command(context.Background(), nil, nil, out); err != nil || !strings.Contains(out.String(), "  status     Show this machine's name in xixo") {
		t.Fatalf("no command printed %q, %v", out, err)
	}

	out.Reset()
	if err := command(context.Background(), []string{"help"}, nil, out); err != nil || !strings.HasPrefix(out.String(), "xixo link connects this machine to xixo") {
		t.Fatalf("help printed %q, %v", out, err)
	}

	out.Reset()
	err := command(context.Background(), []string{"up", "-h"}, nil, out)
	if held := exitStatus(1); !errors.As(err, &held) || held != 0 || !strings.HasPrefix(out.String(), "Usage: xixo-link up\n\nLink up this machine.") || !strings.Contains(out.String(), "-state") {
		t.Fatalf("up -h printed %q, %v", out, err)
	}

	if err := command(context.Background(), []string{"up", "--nope"}, nil, out); err == nil || !strings.HasSuffix(err.Error(), "Run xixo-link up -h to see what it takes") {
		t.Fatalf("a bad flag gave %v", err)
	}

	if err := command(context.Background(), []string{"run", "--config", "/nonexistent/config.json"}, nil, out); err == nil {
		t.Fatal("run started without a config")
	}
}

func TestUpdatesOnlyWhereTheyWork(t *testing.T) {
	t.Setenv("INVOCATION_ID", "")

	run := func(mode string) error {
		return command(context.Background(), []string{"run", "--config", "/nonexistent/config.json", "--updates", mode}, nil, &bytes.Buffer{})
	}

	if err := run("systemd"); !errors.Is(err, errSystemdOnly) {
		t.Fatalf("xixo link outside systemd took --updates systemd: %v", err)
	}

	if runtime.GOOS == "darwin" {
		return
	}

	if err := run("self"); !errors.Is(err, errSelfOnly) {
		t.Fatalf("xixo link off macOS took --updates self: %v", err)
	}
}

func TestSetupThenUnit(t *testing.T) {
	root := t.TempDir()
	config := filepath.Join(root, "config.json")
	template := filepath.Join(root, "xixo-link.service")
	os.WriteFile(template, []byte("User=@USER@\n@FOLDERS@\n"), 0o644)

	out := &bytes.Buffer{}
	if err := command(context.Background(), []string{"setup", "--xixo", "https://xixo.example", "--issuer", "https://id.example", "--config", config, root, filepath.Join(t.TempDir()) + ":rw"}, nil, out); err != nil {
		t.Fatal(err)
	}

	if out.Len() != 0 {
		t.Fatalf("setup printed %q", out)
	}

	out.Reset()
	if err := command(context.Background(), []string{"unit", "--template", template, "--user", "jon", "--config", config}, nil, out); err != nil {
		t.Fatal(err)
	}

	if !strings.HasPrefix(out.String(), "User=jon\nBindReadOnlyPaths=\"-"+root+"\"\nBindPaths=") {
		t.Fatalf("unit printed %q", out)
	}
}

func TestStatusSaysWhatIsMissingAndListsWritableFolders(t *testing.T) {
	serviceState = func() string { return "running" }
	updatesHere = func() bool { return true }
	t.Cleanup(func() { serviceState, updatesHere = runningHere, updatingHere })

	root := t.TempDir()
	config := filepath.Join(root, "config.json")
	inbox := filepath.Join(root, "inbox")
	os.Mkdir(inbox, 0o755)

	if err := command(context.Background(), []string{"setup", "--xixo", "https://xixo.example", "--issuer", "https://id.example", "--config", config, root + "/", inbox + ":rw"}, nil, &bytes.Buffer{}); err == nil {
		t.Fatal("setup took a folder inside another")
	}

	media := filepath.Join(root, "media")
	os.Mkdir(media, 0o755)

	if err := command(context.Background(), []string{"setup", "--xixo", "https://xixo.example", "--issuer", "https://id.example", "--config", config, media, inbox + ":rw"}, nil, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}

	out := &bytes.Buffer{}
	if err := command(context.Background(), []string{"status", "--config", config, "--state", filepath.Join(root, "state")}, nil, out); err != nil {
		t.Fatal(err)
	}

	told := out.String()
	for _, line := range []string{
		"This machine is not linked up with https://xixo.example.\nRun the link-up command from Resources in xixo to link it up.\n",
		"  Service    running\n",
		"  Updates    automatic\n",
		"  Folders    " + media + "  read only\n",
		"             " + inbox + "  read and write\n",
		"To check on xixo link:\n",
	} {
		if !strings.Contains(told, line) {
			t.Fatalf("status left out %q:\n%s", line, told)
		}
	}

	if err := command(context.Background(), []string{"status", "--config", filepath.Join(root, "none.json")}, nil, out); err == nil || !strings.Contains(err.Error(), "not set up on this machine") {
		t.Fatalf("status without a config gave %v", err)
	}
}

func TestStageMakesTheBuildTheCurrentReleaseWithTheReaderBesideIt(t *testing.T) {
	root := t.TempDir()
	work := filepath.Join(root, "work")
	releases := filepath.Join(root, "releases")
	os.Mkdir(work, 0o700)
	os.WriteFile(filepath.Join(work, "xixo-link"), []byte("new build"), 0o755)
	os.WriteFile(filepath.Join(work, "xixo-mac-reader"), []byte("new reader"), 0o755)

	for _, old := range []string{"0123456789abcdef", "fedcba9876543210"} {
		os.MkdirAll(filepath.Join(releases, old), 0o700)
		os.WriteFile(filepath.Join(releases, old, "xixo-link"), []byte(old), 0o755)
	}

	os.Symlink("fedcba9876543210", filepath.Join(releases, "good"))

	name, err := stage(filepath.Join(work, "xixo-link"), releases)
	if err != nil {
		t.Fatal(err)
	}

	if pointed, _ := os.Readlink(filepath.Join(releases, "current")); pointed != name || len(name) != 16 {
		t.Fatalf("current points at %q, staged %q", pointed, name)
	}

	if read, _ := os.ReadFile(filepath.Join(releases, name, "xixo-mac-reader")); string(read) != "new reader" {
		t.Fatalf("the reader holds %q", read)
	}

	if _, err := os.Stat(filepath.Join(releases, "0123456789abcdef")); err == nil {
		t.Fatal("a release nothing points at stayed")
	}

	if _, err := os.Stat(filepath.Join(releases, "fedcba9876543210")); err != nil {
		t.Fatal("the good release went away")
	}

	if again, err := stage(filepath.Join(work, "xixo-link"), releases); err != nil || again != name {
		t.Fatalf("staging again gave %q, %v", again, err)
	}
}
