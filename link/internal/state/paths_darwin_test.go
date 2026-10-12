package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultsLiveInTheUsersLibraryOnMacOS(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip(err)
	}

	support := filepath.Join(home, "Library", "Application Support", "xixo-link")

	if DefaultConfig != filepath.Join(support, "config.json") || DefaultState != filepath.Join(support, "state") {
		t.Fatalf("config %q, state %q", DefaultConfig, DefaultState)
	}

	if DefaultCache != filepath.Join(home, "Library", "Caches", "xixo-link") {
		t.Fatalf("cache %q", DefaultCache)
	}
}
