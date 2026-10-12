package main

import (
	"bytes"
	"context"
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
