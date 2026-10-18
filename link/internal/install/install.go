package install

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/xixo/xixo/link/internal/parts"
	"github.com/xixo/xixo/link/internal/state"
)

const (
	Updater     = "xixo-link-update"
	Lib         = "/usr/local/lib/xixo-link"
	Bin         = "/usr/local/bin/xixo-link"
	Etc         = "/etc/xixo-link"
	Units       = "/etc/systemd/system"
	StateDir    = "/var/lib/xixo-link"
	PartsState  = "/var/lib/xixo-link-part"
	Cache       = "/var/cache/xixo-link"
	Service     = "xixo-link.service"
	UpdateUnit  = "xixo-link-update.service"
	UpdatePath  = "xixo-link-update.path"
	PartUnit    = "xixo-link-part@.service"
	PartPath    = "xixo-link-part@.path"
	Plist       = "xixo-link.plist"
	LaunchLabel = "network.xixo.link"
	mostUnit    = 64 << 10
)

var (
	ErrNoRoot = errors.New("installing on Linux needs root: run it with sudo")
	ErrNoFrom = errors.New("install takes --from, the build to install")
)

type Installer struct {
	Root    string
	Xixo    string
	Issuer  string
	User    string
	From    string
	Folders []string
	Client  *http.Client
	Out     io.Writer
	Run     func(ctx context.Context, name string, args ...string) error
	Lookup  func(name string) (int, int, error)
	Stage   func(from, releases string) (string, error)
	Home    string
}

func (i *Installer) run(ctx context.Context, name string, args ...string) error {
	if i.Run != nil {
		return i.Run(ctx, name, args...)
	}

	command := exec.CommandContext(ctx, name, args...)
	command.Stdout = i.out()
	command.Stderr = i.out()

	return command.Run()
}

func (i *Installer) out() io.Writer {
	if i.Out != nil {
		return i.Out
	}

	return io.Discard
}

func (i *Installer) path(held string) string {
	return filepath.Join(i.Root, held)
}

func (i *Installer) lookup(name string) (int, int, error) {
	if i.Lookup != nil {
		return i.Lookup(name)
	}

	held, err := user.Lookup(name)
	if err != nil {
		return 0, 0, err
	}

	uid, _ := strconv.Atoi(held.Uid)
	gid, _ := strconv.Atoi(held.Gid)

	return uid, gid, nil
}

func (i *Installer) fetch(ctx context.Context, name string) ([]byte, error) {
	return i.fetchUpTo(ctx, name, mostUnit)
}

func (i *Installer) fetchUpTo(ctx context.Context, name string, most int64) ([]byte, error) {
	client := i.Client
	if client == nil {
		client = http.DefaultClient
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(i.Xixo, "/")+"/link/download/"+name, nil)
	if err != nil {
		return nil, err
	}

	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("%s did not download from %s: %w", name, i.Xixo, err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s did not download from %s: %s", name, i.Xixo, response.Status)
	}

	return io.ReadAll(io.LimitReader(response.Body, most))
}

func (i *Installer) Linux(ctx context.Context) error {
	if i.From == "" {
		return ErrNoFrom
	}

	if i.Root == "" && os.Geteuid() != 0 {
		return ErrNoRoot
	}

	if _, _, err := i.lookup(Updater); err != nil {
		if err := i.run(ctx, "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent", "--shell", "/usr/sbin/nologin", Updater); err != nil {
			return fmt.Errorf("the %s account could not be made: %w", Updater, err)
		}
	}

	uid, gid, err := i.lookup(Updater)
	if err != nil {
		return err
	}

	lib := i.path(Lib)
	if err := os.MkdirAll(lib, 0o755); err != nil {
		return err
	}

	if err := os.Chown(lib, uid, gid); err != nil && i.Root == "" {
		return err
	}

	if err := copied(i.From, filepath.Join(lib, "xixo-link"), 0o755, uid, gid, i.Root == ""); err != nil {
		return err
	}

	os.Remove(filepath.Join(lib, "xixo-link.previous"))

	if err := os.MkdirAll(filepath.Dir(i.path(Bin)), 0o755); err != nil {
		return err
	}

	os.Remove(i.path(Bin))

	if err := os.Symlink(Lib+"/xixo-link", i.path(Bin)); err != nil {
		return err
	}

	if err := os.MkdirAll(i.path(Etc), 0o755); err != nil {
		return err
	}

	config, err := state.Setup(i.path(Etc+"/config.json"), i.Xixo, i.Issuer, i.Folders)
	if err != nil {
		return err
	}

	template, err := i.fetch(ctx, Service)
	if err != nil {
		return err
	}

	unit, err := state.Unit(string(template), i.User, config.Folders)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(i.path(Units), 0o755); err != nil {
		return err
	}

	if err := os.WriteFile(i.path(Units+"/"+Service), []byte(unit), 0o644); err != nil {
		return err
	}

	for _, name := range []string{UpdateUnit, UpdatePath} {
		raw, err := i.fetch(ctx, name)
		if err != nil {
			return err
		}

		if err := os.WriteFile(i.path(Units+"/"+name), raw, 0o644); err != nil {
			return err
		}
	}

	partUnits := true

	for _, name := range []string{PartUnit, PartPath} {
		raw, err := i.fetch(ctx, name)
		if err != nil {
			partUnits = false
			fmt.Fprintf(i.out(), "   xixo serves no %s yet, so this machine runs no parts until it is updated.\n", name)

			break
		}

		if err := os.WriteFile(i.path(Units+"/"+name), raw, 0o644); err != nil {
			return err
		}
	}

	userID, userGID, err := i.lookup(i.User)
	if err != nil {
		return fmt.Errorf("%q is not an account on this machine: %w", i.User, err)
	}

	if err := os.MkdirAll(i.path(StateDir), 0o700); err != nil {
		return err
	}

	if err := os.Chown(i.path(StateDir), userID, userGID); err != nil && i.Root == "" {
		return err
	}

	if err := i.run(ctx, "systemctl", "daemon-reload"); err != nil {
		return err
	}

	if err := i.run(ctx, "systemctl", "enable", "--quiet", "xixo-link"); err != nil {
		return err
	}

	if err := i.run(ctx, "systemctl", "enable", "--now", "--quiet", UpdatePath); err != nil {
		return err
	}

	if partUnits {
		for _, part := range parts.Known() {
			if err := i.run(ctx, "systemctl", "enable", "--now", "--quiet", "xixo-link-part@"+part+".path"); err != nil {
				return err
			}
		}
	}

	return nil
}

func (i *Installer) StartLinux(ctx context.Context) error {
	if err := i.run(ctx, "systemctl", "daemon-reload"); err != nil {
		return err
	}

	if err := i.run(ctx, "systemctl", "restart", "xixo-link"); err != nil {
		return fmt.Errorf("systemd did not start xixo link. See why with: journalctl -u xixo-link -n 50: %w", err)
	}

	return nil
}

func (i *Installer) UninstallLinux(ctx context.Context) error {
	units := []string{"xixo-link", UpdatePath, UpdateUnit}
	for _, part := range parts.Known() {
		units = append(units, "xixo-link-part@"+part+".path", "xixo-link-part@"+part+".service")
	}

	i.run(ctx, "systemctl", append([]string{"disable", "--now", "--quiet"}, units...)...)

	for _, name := range []string{Service, UpdateUnit, UpdatePath, PartUnit, PartPath} {
		os.Remove(i.path(Units + "/" + name))
	}

	i.run(ctx, "systemctl", "daemon-reload")

	for _, held := range []string{Bin, Lib, Etc, StateDir, Cache, PartsState} {
		if err := os.RemoveAll(i.path(held)); err != nil {
			return err
		}
	}

	return nil
}

func copied(from, to string, mode os.FileMode, uid, gid int, own bool) error {
	raw, err := os.ReadFile(from)
	if err != nil {
		return err
	}

	part := to + ".part"
	if err := os.WriteFile(part, raw, mode); err != nil {
		return err
	}

	if own {
		if err := os.Chown(part, uid, gid); err != nil {
			os.Remove(part)

			return err
		}
	}

	return os.Rename(part, to)
}
