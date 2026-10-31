package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/xixo/xixo/link/internal/parts"
	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/state"
)

const (
	Lib          = "/usr/local/lib/xixo-link"
	Bin          = "/usr/local/bin/xixo-link"
	Etc          = "/etc/xixo-link"
	UnitsDir     = "/etc/systemd/system"
	Cache        = "/var/cache/xixo-link-update"
	ReleasesDir  = "releases"
	StagedDir    = "staged"
	InstallFile  = "install.json"
	PackagesFile = "packages"
	BadFile      = "bad"
	Service      = release.Service
	FetchUnit    = "xixo-link-fetch.service"
	UpdateUnit   = "xixo-link-update.service"
	UpdatePath   = "xixo-link-update.path"
	UpdateTimer  = "xixo-link-update.timer"
	PackagesUnit = "xixo-link-packages.service"
	PartUnit     = "xixo-link-part@.service"
	PartPath     = "xixo-link-part@.path"
	LinkUnit     = "xixo-link"
	mostUnit     = 64 << 10
)

var (
	ErrNotStaged = errors.New("a file the release lists is not in the folder it was fetched into")
	ErrNoUser    = errors.New("the install names no account for xixo link to run as")
)

type Installed struct {
	User string `json:"user"`
}

type Layout struct {
	Root string
}

func (l Layout) at(held string) string {
	return filepath.Join(l.Root, held)
}

func (l Layout) Lib() string      { return l.at(Lib) }
func (l Layout) Bin() string      { return l.at(Bin) }
func (l Layout) Etc() string      { return l.at(Etc) }
func (l Layout) Units() string    { return l.at(UnitsDir) }
func (l Layout) Cache() string    { return l.at(Cache) }
func (l Layout) Releases() string { return filepath.Join(l.Lib(), ReleasesDir) }
func (l Layout) Staged() string   { return filepath.Join(l.Cache(), StagedDir) }
func (l Layout) Binary() string   { return filepath.Join(l.Lib(), Binary) }
func (l Layout) Config() string   { return filepath.Join(l.Etc(), "config.json") }
func (l Layout) Install() string  { return filepath.Join(l.Etc(), InstallFile) }
func (l Layout) Floor() string    { return filepath.Join(l.Lib(), FloorFile) }
func (l Layout) Trust() string    { return filepath.Join(l.Lib(), TrustDir) }
func (l Layout) Packages() string { return filepath.Join(l.Lib(), PackagesFile) }
func (l Layout) Bad() string      { return filepath.Join(l.Lib(), BadFile) }

func (l Layout) Release(id string) string {
	return filepath.Join(l.Releases(), id)
}

func (l Layout) Held(id string) (release.Release, error) {
	raw, err := os.ReadFile(filepath.Join(l.Release(id), release.File))
	if err != nil {
		return release.Release{}, err
	}

	return release.Parse(raw)
}

func (l Layout) User() (string, error) {
	held := Installed{}
	if err := Read(l.Install(), &held); err != nil {
		return "", fmt.Errorf("%w: %v", ErrNoUser, err)
	}

	if held.User == "" {
		return "", ErrNoUser
	}

	return held.User, nil
}

type Placer struct {
	Layout
	Run func(ctx context.Context, name string, args ...string) error
	Out io.Writer
	Log *slog.Logger
}

func (p *Placer) run(ctx context.Context, name string, args ...string) error {
	if p.Run != nil {
		return p.Run(ctx, name, args...)
	}

	command := exec.CommandContext(ctx, name, args...)
	command.Stdout = p.out()
	command.Stderr = p.out()

	return command.Run()
}

func (p *Placer) out() io.Writer {
	if p.Out != nil {
		return p.Out
	}

	return io.Discard
}

func (p *Placer) log() *slog.Logger {
	if p.Log != nil {
		return p.Log
	}

	return slog.New(slog.DiscardHandler)
}

func (p *Placer) Keep(held Verified, files []release.Entry, from string) error {
	if err := os.MkdirAll(p.Releases(), 0o755); err != nil {
		return err
	}

	part := filepath.Join(p.Releases(), ".part-"+held.ID)
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

	for _, entry := range files {
		name, mode := entry.Name, os.FileMode(0o644)
		if entry.Role == release.RoleBinary {
			name, mode = Binary, 0o755
		}

		if err := checked(filepath.Join(from, filepath.FromSlash(entry.Name)), filepath.Join(part, name), entry, mode); err != nil {
			return err
		}
	}

	placed := p.Release(held.ID)
	if err := os.RemoveAll(placed); err != nil {
		return err
	}

	if err := os.Rename(part, placed); err != nil {
		return err
	}

	done = true

	return syncDir(p.Releases())
}

func checked(from, to string, entry release.Entry, mode os.FileMode) error {
	source, err := os.OpenFile(from, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("%w: %s: %v", ErrNotStaged, entry.Name, err)
	}
	defer source.Close()

	info, err := source.Stat()
	if err != nil {
		return err
	}

	if !info.Mode().IsRegular() {
		return fmt.Errorf("%w: %s is not a regular file", ErrNotStaged, entry.Name)
	}

	if info.Size() != entry.Size {
		return fmt.Errorf("%w: %s is %d bytes, and the release lists %d", ErrMismatch, entry.Name, info.Size(), entry.Size)
	}

	kept, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}

	hashed := sha256.New()
	written, err := io.Copy(io.MultiWriter(kept, hashed), io.LimitReader(source, entry.Size+1))

	if err == nil && (written != entry.Size || hex.EncodeToString(hashed.Sum(nil)) != entry.SHA256) {
		err = fmt.Errorf("%w: %s does not hash to %s", ErrMismatch, entry.Name, entry.SHA256)
	}

	if err == nil {
		err = kept.Sync()
	}

	if closed := kept.Close(); err == nil {
		err = closed
	}

	if err != nil {
		os.Remove(to)
	}

	return err
}

func (p *Placer) Render(id string) (bool, error) {
	user, err := p.User()
	if err != nil {
		return false, err
	}

	config, err := state.LoadConfig(p.Config())
	if err != nil {
		return false, err
	}

	held, err := p.Held(id)
	if err != nil {
		return false, err
	}

	if err := os.MkdirAll(p.Units(), 0o755); err != nil {
		return false, err
	}

	changed := false

	for _, entry := range held.Units() {
		raw, err := os.ReadFile(filepath.Join(p.Release(id), entry.Name))
		if err != nil {
			return changed, err
		}

		if len(raw) > mostUnit {
			return changed, fmt.Errorf("%s is larger than %d bytes", entry.Name, mostUnit)
		}

		body := string(raw)
		if entry.Name == Service {
			if body, err = state.Unit(body, user, config.Folders); err != nil {
				return changed, err
			}
		}

		target := filepath.Join(p.Units(), entry.Name)
		if have, err := os.ReadFile(target); err == nil && string(have) == body {
			continue
		}

		if err := replaced(target, []byte(body), 0o644); err != nil {
			return changed, err
		}

		p.log().Info("a unit changed", "unit", entry.Name, "release", id)
		changed = true
	}

	return changed, nil
}

func replaced(target string, body []byte, mode os.FileMode) error {
	part := target + ".part"
	if err := os.WriteFile(part, body, mode); err != nil {
		return err
	}

	if err := os.Chmod(part, mode); err != nil {
		os.Remove(part)

		return err
	}

	if err := os.Rename(part, target); err != nil {
		os.Remove(part)

		return err
	}

	return nil
}

func (p *Placer) Link(id string) error {
	if err := Point(p.Releases(), Current, id); err != nil {
		return err
	}

	if err := linked(p.Binary(), filepath.Join(ReleasesDir, Current, Binary)); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(p.Bin()), 0o755); err != nil {
		return err
	}

	return linked(p.Bin(), filepath.Join(Lib, Binary))
}

func linked(path, target string) error {
	if held, err := os.Readlink(path); err == nil && held == target {
		return nil
	}

	part := path + ".part"
	os.Remove(part)

	if err := os.Symlink(target, part); err != nil {
		return err
	}

	if err := os.Rename(part, path); err != nil {
		os.Remove(part)

		return err
	}

	return syncDir(filepath.Dir(path))
}

func (p *Placer) Reload(ctx context.Context) error {
	return p.run(ctx, "systemctl", "daemon-reload")
}

func (p *Placer) Restart(ctx context.Context) error {
	return p.run(ctx, "systemctl", "restart", LinkUnit)
}

func (p *Placer) Enable(ctx context.Context) error {
	if err := p.run(ctx, "systemctl", "enable", "--quiet", LinkUnit); err != nil {
		return err
	}

	if err := p.run(ctx, "systemctl", "enable", "--now", "--quiet", UpdatePath, UpdateTimer); err != nil {
		return err
	}

	for _, part := range parts.Known() {
		if err := p.run(ctx, "systemctl", "enable", "--now", "--quiet", "xixo-link-part@"+part+".path"); err != nil {
			return err
		}
	}

	return nil
}

func (l Layout) Pointed(pointer string) string {
	return Pointed(l.Releases(), pointer)
}

func (l Layout) Promote(id string) error {
	return Point(l.Releases(), Good, id)
}

func (l Layout) Refuse(id string) error {
	return Write(l.Bad(), id, 0o644)
}

func (l Layout) Refused(id string) bool {
	held := ""

	return Read(l.Bad(), &held) == nil && held == id
}
