package state

import (
	"os"
	"path/filepath"
)

var (
	DefaultConfig, DefaultState, DefaultCache = defaults()
	SearchPath                                = []string{"/opt/homebrew/bin", "/usr/local/bin", "/Applications/LibreOffice.app/Contents/MacOS"}
)

func defaults() (string, string, string) {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return "config.json", "state", ""
	}

	support := filepath.Join(home, "Library", "Application Support", "xixo-agent")

	return filepath.Join(support, "config.json"), filepath.Join(support, "state"), filepath.Join(home, "Library", "Caches", "xixo-agent")
}
