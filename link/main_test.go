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

	if err := command(context.Background(), nil, nil, out); err == nil {
		t.Fatal("no command ran")
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

	if !strings.HasPrefix(out.String(), "Shares "+root+" and ") {
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
