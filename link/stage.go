package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"

	"github.com/xixo/xixo/link/internal/update"
)

var errStageMacOnly = errors.New("stage installs an update for the launch agent, which only macOS has")

func staged(releases string) error {
	if runtime.GOOS != "darwin" {
		return errStageMacOnly
	}

	self, err := executable()
	if err != nil {
		return err
	}

	_, err = stage(self, releases)

	return err
}

func stage(self, releases string) (string, error) {
	digest, err := update.Digest(self)
	if err != nil {
		return "", err
	}

	name := digest[:16]

	if err := os.MkdirAll(releases, 0o700); err != nil {
		return "", err
	}

	part, err := os.MkdirTemp(releases, ".part-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(part)

	if err := copied(self, filepath.Join(part, update.Binary)); err != nil {
		return "", err
	}

	reader := filepath.Join(filepath.Dir(self), update.MacReader)
	if info, err := os.Lstat(reader); err == nil && info.Mode().IsRegular() {
		if err := copied(reader, filepath.Join(part, update.MacReader)); err != nil {
			return "", err
		}
	}

	placed := filepath.Join(releases, name)

	if err := os.RemoveAll(placed); err != nil {
		return "", err
	}

	if err := os.Rename(part, placed); err != nil {
		return "", err
	}

	if err := update.Point(releases, update.Current, name); err != nil {
		return "", err
	}

	update.Prune(releases, name)

	return name, nil
}

func copied(from, to string) error {
	source, err := os.Open(from)
	if err != nil {
		return err
	}
	defer source.Close()

	kept, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o755)
	if err != nil {
		return err
	}

	if _, err := io.Copy(kept, source); err != nil {
		kept.Close()

		return err
	}

	if err := kept.Sync(); err != nil {
		kept.Close()

		return err
	}

	return kept.Close()
}
