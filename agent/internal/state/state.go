package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/agent/internal/dial"
	"github.com/xixo/xixo/agent/internal/folders"
)

const Scope = "xixo:agent"

const (
	ToolBrowse  = "browse"
	ToolSearch  = "search"
	ToolRead    = "read"
	ToolWrite   = "write"
	ToolExtract = "extract"
	ToolModels  = "models"
)

var Tools = []string{ToolBrowse, ToolSearch, ToolRead, ToolWrite, ToolExtract, ToolModels}

type Config struct {
	Xixo               string           `json:"xixo"`
	Issuer             string           `json:"issuer"`
	Folders            []folders.Shared `json:"folders"`
	Lend               bool             `json:"lend"`
	ExtractsForOthers  bool             `json:"extracts_for_others"`
	ExtractUnsandboxed bool             `json:"extract_unsandboxed"`
	Tools              []string         `json:"tools"`
}

func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	held := &Config{}
	if err := json.Unmarshal(raw, held); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}

	return held, held.check()
}

func (c *Config) check() error {
	c.Xixo = strings.TrimSuffix(c.Xixo, "/")
	c.Issuer = strings.TrimSuffix(c.Issuer, "/")

	if err := secure("xixo", c.Xixo); err != nil {
		return err
	}

	if err := secure("issuer", c.Issuer); err != nil {
		return err
	}

	for _, tool := range c.Tools {
		if !slices.Contains(Tools, tool) {
			return fmt.Errorf("the tool %q is not one the agent offers: name any of %s", tool, strings.Join(Tools, ", "))
		}
	}

	seen := map[string]bool{}

	for _, folder := range c.Folders {
		if !filepath.IsAbs(folder.Path) || filepath.Clean(folder.Path) != folder.Path {
			return fmt.Errorf("the folder %q is not a clean absolute path", folder.Path)
		}

		if writable, held := seen[folder.Path]; held && writable != folder.Writable {
			return fmt.Errorf("the folder %q is listed both writable and read-only", folder.Path)
		}

		seen[folder.Path] = folder.Writable
	}

	for outer := range seen {
		for inner := range seen {
			if outer != inner && within(inner, outer) {
				return fmt.Errorf("the folder %q lies inside the folder %q: share one or the other", inner, outer)
			}
		}
	}

	return nil
}

func within(inner, outer string) bool {
	return outer == string(filepath.Separator) || strings.HasPrefix(inner, outer+string(filepath.Separator))
}

func (c *Config) Resource() string {
	return c.Xixo + "/mcp"
}

func secure(named, raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("the %s address %q is not a URL", named, raw)
	}

	if parsed.Scheme == "https" || (parsed.Scheme == "http" && dial.Local(parsed.Hostname())) {
		return nil
	}

	return fmt.Errorf("the %s address %q must use https", named, raw)
}

type State struct {
	Dir string
}

func (s State) path(name string) string {
	return filepath.Join(s.Dir, name)
}

var ErrNoKeys = errors.New("this machine holds no keys: run xixo-agent enroll first")

func (s State) Keys() (*masks.Key, *masks.Key, error) {
	key, err := s.key("key.json")
	if err != nil {
		return nil, nil, err
	}

	dpop, err := s.key("dpop.json")
	if err != nil {
		return nil, nil, err
	}

	return key, dpop, nil
}

func (s State) MakeKeys() (*masks.Key, *masks.Key, error) {
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return nil, nil, err
	}

	if err := os.Chmod(s.Dir, 0o700); err != nil {
		return nil, nil, err
	}

	key, err := s.made("key.json")
	if err != nil {
		return nil, nil, err
	}

	dpop, err := s.made("dpop.json")
	if err != nil {
		return nil, nil, err
	}

	return key, dpop, nil
}

func (s State) key(name string) (*masks.Key, error) {
	raw, err := os.ReadFile(s.path(name))

	switch {
	case errors.Is(err, fs.ErrNotExist) || (err == nil && len(raw) == 0):
		return nil, fmt.Errorf("%w: %s is missing", ErrNoKeys, name)
	case err != nil:
		return nil, err
	}

	return masks.ParseKey(raw)
}

func (s State) made(name string) (*masks.Key, error) {
	held, err := s.key(name)
	if !errors.Is(err, ErrNoKeys) {
		return held, err
	}

	made, err := masks.GenerateKey()
	if err != nil {
		return nil, err
	}

	encoded, err := json.Marshal(made)
	if err != nil {
		return nil, err
	}

	return made, write(s.path(name), encoded)
}

func (s State) Registration() (*masks.Registration, error) {
	raw, err := os.ReadFile(s.path("registration.json"))
	if err != nil {
		return nil, err
	}

	held := &masks.Registration{}

	return held, json.Unmarshal(raw, held)
}

func (s State) Keep(held *masks.Registration) error {
	kept := *held
	kept.RegistrationAccessToken = ""
	kept.RegistrationClientURI = ""

	encoded, err := json.MarshalIndent(&kept, "", "  ")
	if err != nil {
		return err
	}

	return write(s.path("registration.json"), encoded)
}

func write(path string, data []byte) error {
	temporary := path + ".tmp"

	opened, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}

	_, err = opened.Write(data)
	if err == nil {
		err = opened.Sync()
	}

	if closed := opened.Close(); err == nil {
		err = closed
	}

	if err != nil {
		os.Remove(temporary)

		return err
	}

	if err := os.Rename(temporary, path); err != nil {
		return err
	}

	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()

	return dir.Sync()
}
