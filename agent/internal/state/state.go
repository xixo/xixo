package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	masks "github.com/masksrb/masks/go"
)

const (
	DefaultConfig = "/etc/xixo-agent/config.json"
	DefaultState  = "/var/lib/xixo-agent"
	Scope         = "xixo:agent"
)

type Config struct {
	Xixo    string   `json:"xixo"`
	Issuer  string   `json:"issuer"`
	Folders []string `json:"folders"`
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

	for _, folder := range c.Folders {
		if !filepath.IsAbs(folder) {
			return fmt.Errorf("the folder %q is not an absolute path", folder)
		}
	}

	return nil
}

func (c *Config) Resource() string {
	return c.Xixo + "/mcp"
}

func secure(named, raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("the %s address %q is not a URL", named, raw)
	}

	if parsed.Scheme == "https" || (parsed.Scheme == "http" && loopback(parsed.Hostname())) {
		return nil
	}

	return fmt.Errorf("the %s address %q must use https", named, raw)
}

func loopback(host string) bool {
	return host == "localhost" || strings.HasSuffix(host, ".localhost") || host == "127.0.0.1" || host == "::1"
}

type State struct {
	Dir string
}

func (s State) path(name string) string {
	return filepath.Join(s.Dir, name)
}

func (s State) Keys() (*masks.Key, *masks.Key, error) {
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return nil, nil, err
	}

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

func (s State) key(name string) (*masks.Key, error) {
	raw, err := os.ReadFile(s.path(name))

	switch {
	case err == nil:
		return masks.ParseKey(raw)
	case !errors.Is(err, fs.ErrNotExist):
		return nil, err
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
	encoded, err := json.MarshalIndent(held, "", "  ")
	if err != nil {
		return err
	}

	return write(s.path("registration.json"), encoded)
}

func write(path string, data []byte) error {
	temporary := path + ".tmp"

	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}

	return os.Rename(temporary, path)
}
