package parts

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

const (
	StateMissing  = "missing"
	StateFetching = "fetching"
	StateStarting = "starting"
	StateRunning  = "running"
	StateFailed   = "failed"
	StateStopped  = "stopped"
)

type Settings struct {
	Port      int      `json:"port"`
	Models    []string `json:"models"`
	Context   int      `json:"context"`
	KeepAlive string   `json:"keep_alive"`
}

type Wanted struct {
	Version  string   `json:"version"`
	Settings Settings `json:"settings"`
}

type Pull struct {
	Model string `json:"model"`
	Done  int64  `json:"done"`
	Total int64  `json:"total"`
	Ready bool   `json:"ready"`
	Error string `json:"error,omitempty"`
}

type Status struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	State   string `json:"state"`
	Port    int    `json:"port,omitempty"`
	Warning string `json:"warning,omitempty"`
	Pulls   []Pull `json:"pulls"`
	At      string `json:"at"`
}

func ReadWanted(path string) (*Wanted, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	held := &Wanted{}
	if err := json.Unmarshal(raw, held); err != nil {
		return nil, err
	}

	if held.Settings.Port <= 0 || held.Settings.Port > 65535 {
		held.Settings.Port = DefaultPort
	}

	return held, nil
}

func WriteWanted(path string, wanted Wanted) error {
	raw, err := json.Marshal(wanted)
	if err != nil {
		return err
	}

	return written(path, raw, 0o644)
}

func Unwant(path string) error {
	err := os.Remove(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}

	return err
}

func ReadStatus(path string) (Status, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Status{}, err
	}

	held := Status{}
	if err := json.Unmarshal(raw, &held); err != nil {
		return Status{}, err
	}

	if held.Pulls == nil {
		held.Pulls = []Pull{}
	}

	return held, nil
}

func WriteStatus(path string, status Status) error {
	status.At = time.Now().UTC().Format(time.RFC3339)
	if status.Pulls == nil {
		status.Pulls = []Pull{}
	}

	raw, err := json.Marshal(status)
	if err != nil {
		return err
	}

	return written(path, raw, 0o644)
}

func written(path string, raw []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, raw, mode); err != nil {
		return err
	}

	return os.Rename(temporary, path)
}
