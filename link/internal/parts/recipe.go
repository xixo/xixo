package parts

import (
	"errors"
	"fmt"
	"runtime"
)

const (
	Models      = "models"
	ArchiveZstd = "tar.zst"
	ArchiveGzip = "tgz"
	DefaultPort = 11440
	MostBuild   = 4 << 30
)

type Build struct {
	URL     string
	SHA256  string
	Archive string
	Command string
}

type Recipe struct {
	Name    string
	Version string
	Builds  map[string]Build
	Health  string
	Args    []string
}

var ErrNoBuild = errors.New("this part has no build for this system and processor")

var ollama = Recipe{
	Name:    Models,
	Version: "0.40.6",
	Health:  "/api/version",
	Args:    []string{"serve"},
	Builds: map[string]Build{
		"linux-amd64": {
			URL:     "https://github.com/ollama/ollama/releases/download/v0.40.6/ollama-linux-amd64.tar.zst",
			SHA256:  "c164ab8b1b28e2a247c29719b8e404c423c5b83ae64c3ab4e59d50c7ff7fc5e0",
			Archive: ArchiveZstd,
			Command: "bin/ollama",
		},
		"linux-arm64": {
			URL:     "https://github.com/ollama/ollama/releases/download/v0.40.6/ollama-linux-arm64.tar.zst",
			SHA256:  "0a279d9428ad17b06fdb7dddf3b059b2c148433585fa3b30676a102fc459bb9f",
			Archive: ArchiveZstd,
			Command: "bin/ollama",
		},
		"darwin-arm64": {
			URL:     "https://github.com/ollama/ollama/releases/download/v0.40.6/ollama-darwin.tgz",
			SHA256:  "b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974",
			Archive: ArchiveGzip,
			Command: "ollama",
		},
		"darwin-amd64": {
			URL:     "https://github.com/ollama/ollama/releases/download/v0.40.6/ollama-darwin.tgz",
			SHA256:  "b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974",
			Archive: ArchiveGzip,
			Command: "ollama",
		},
	},
}

var Recipes = map[string]Recipe{Models: ollama}

func Known() []string {
	return []string{Models}
}

func (r Recipe) Build() (Build, error) {
	return r.BuildFor(runtime.GOOS, runtime.GOARCH)
}

func (r Recipe) BuildFor(goos, goarch string) (Build, error) {
	held, ok := r.Builds[goos+"-"+goarch]
	if !ok {
		return Build{}, fmt.Errorf("%w: %s on %s", ErrNoBuild, goos, goarch)
	}

	return held, nil
}
