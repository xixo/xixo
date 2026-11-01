package update

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/xixo/xixo/link/internal/release"
)

const (
	FetchFile   = "fetch.json"
	RequestKept = "request.json"
)

type Fetcher struct {
	Xixo     string
	Requests string
	Cache    string
	OS       string
	Arch     string
	Client   *http.Client
	Vouch    *Vouch
	Log      *slog.Logger
}

func (f *Fetcher) log() *slog.Logger {
	if f.Log != nil {
		return f.Log
	}

	return slog.New(slog.DiscardHandler)
}

func (f *Fetcher) Fetch(ctx context.Context) error {
	asked := Request{}
	if err := Read(filepath.Join(f.Requests, RequestFile), &asked); err != nil {
		if missing(err) {
			return nil
		}

		return err
	}

	if err := asked.Check(); err != nil {
		return err
	}

	if asked.RollBack {
		f.note(asked, nil)

		return nil
	}

	err := f.fetch(ctx, asked)
	f.note(asked, err)

	return err
}

func (f *Fetcher) fetch(ctx context.Context, asked Request) error {
	goos, goarch := system(f.OS, f.Arch)

	held, err := f.Vouch.Release(ctx, asked.Target, goos, goarch)
	if err != nil {
		return err
	}

	staged := Layout{}.stagedIn(f.Cache)
	if err := os.MkdirAll(staged, 0o755); err != nil {
		return err
	}

	if _, err := os.Stat(filepath.Join(staged, held.ID, release.File)); err == nil {
		return nil
	}

	files, err := held.Linux(goarch)
	if err != nil {
		return err
	}

	f.log().Info("fetching a release", "version", held.Version, "serial", held.Serial, "files", len(files))

	part := filepath.Join(staged, ".part-"+held.ID)
	os.RemoveAll(part)

	if err := os.Mkdir(part, 0o755); err != nil {
		return err
	}

	done := false
	defer func() {
		if !done {
			os.RemoveAll(part)
		}
	}()

	if err := os.WriteFile(filepath.Join(part, release.File), held.Raw, 0o644); err != nil {
		return err
	}

	if len(held.Bundle) > 0 {
		if err := os.WriteFile(filepath.Join(part, release.Bundle), held.Bundle, 0o644); err != nil {
			return err
		}
	}

	if err := Write(filepath.Join(part, RequestKept), asked, 0o644); err != nil {
		return err
	}

	for _, entry := range files {
		fetched, err := Fetch(ctx, f.Client, Address(f.Xixo, entry.Name), entry.SHA256, part)
		if err != nil {
			return fmt.Errorf("%s: %w", entry.Name, err)
		}

		mode := os.FileMode(0o644)
		if entry.Role == release.RoleBinary {
			mode = 0o755
		}

		if err := os.Chmod(fetched, mode); err != nil {
			return err
		}

		if err := os.Rename(fetched, filepath.Join(part, entry.Name)); err != nil {
			return err
		}
	}

	pruned(staged, filepath.Base(part))

	if err := os.Rename(part, filepath.Join(staged, held.ID)); err != nil {
		return err
	}

	done = true

	return syncDir(staged)
}

func (f *Fetcher) note(asked Request, err error) {
	told := Result{Version: asked.Version, SHA256: asked.SHA256, RequestedAt: asked.RequestedAt, OK: err == nil, At: time.Now().UTC()}
	if err != nil {
		told.Error = err.Error()
	}

	if werr := Write(filepath.Join(f.Cache, FetchFile), told, 0o644); werr != nil && !errors.Is(werr, os.ErrNotExist) {
		f.log().Warn("the fetch's result could not be kept", "error", werr)
	}
}

func (l Layout) stagedIn(cache string) string {
	return filepath.Join(cache, StagedDir)
}

func pruned(staged, keep string) {
	entries, err := os.ReadDir(staged)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if entry.Name() != keep {
			os.RemoveAll(filepath.Join(staged, entry.Name()))
		}
	}
}

func Staged(staged string) (string, string) {
	entries, err := os.ReadDir(staged)
	if err != nil {
		return "", ""
	}

	for _, entry := range entries {
		if entry.IsDir() && releaseName.MatchString(entry.Name()) {
			return filepath.Join(staged, entry.Name()), entry.Name()
		}
	}

	return "", ""
}
