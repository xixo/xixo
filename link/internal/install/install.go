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
	"runtime"
	"strconv"

	"github.com/xixo/xixo/link/internal/parts"
	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/update"
)

const (
	Updater     = "xixo-link-update"
	PartUser    = "xixo-link-part"
	Lib         = update.Lib
	Bin         = update.Bin
	Etc         = update.Etc
	Units       = update.UnitsDir
	StateDir    = "/var/lib/xixo-link"
	PartsState  = "/var/lib/xixo-link-part"
	Cache       = "/var/cache/xixo-link"
	Service     = update.Service
	Plist       = release.Plist
	LaunchLabel = "network.xixo.link"
	mostUnit    = 64 << 10
)

var (
	ErrNoRoot    = errors.New("installing on Linux needs root: run it with sudo")
	ErrNoFrom    = errors.New("install takes --from, the build to install")
	ErrNotListed = errors.New("the xixo link you downloaded is not the build the release lists. Run the link-up command again")

	LinuxUnits = []string{Service, update.FetchUnit, update.UpdateUnit, update.UpdatePath, update.UpdateTimer, update.PackagesUnit, update.PartUnit, update.PartPath}
)

type Installer struct {
	Root     string
	Xixo     string
	Issuer   string
	User     string
	From     string
	Arch     string
	Folders  []string
	Unsigned bool
	Client   *http.Client
	Out      io.Writer
	Run      func(ctx context.Context, name string, args ...string) error
	Lookup   func(name string) (int, int, error)
	LookPath func(name string) (string, error)
	Stage    func(from, releases string) (string, error)
	Vouch    *update.Vouch
	Home     string
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

func (i *Installer) layout() update.Layout {
	return update.Layout{Root: i.Root}
}

func (i *Installer) placer() *update.Placer {
	return &update.Placer{Layout: i.layout(), Run: i.Run, Out: i.Out}
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

func (i *Installer) client() *http.Client {
	if i.Client != nil {
		return i.Client
	}

	return http.DefaultClient
}

func (i *Installer) fetch(ctx context.Context, name string) ([]byte, error) {
	return i.fetchUpTo(ctx, name, mostUnit)
}

func (i *Installer) fetchUpTo(ctx context.Context, name string, most int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, update.Address(i.Xixo, name), nil)
	if err != nil {
		return nil, err
	}

	response, err := i.client().Do(request)
	if err != nil {
		return nil, fmt.Errorf("%s did not download from %s: %w", name, i.Xixo, err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s did not download from %s: %s", name, i.Xixo, response.Status)
	}

	return io.ReadAll(io.LimitReader(response.Body, most))
}

func (i *Installer) vouch(config *state.Config) *update.Vouch {
	if i.Vouch != nil {
		return i.Vouch
	}

	held := i.layout()

	return &update.Vouch{
		Xixo: config.Xixo, Client: i.client(), Unsigned: config.Unsigned(),
		Floor: held.Floor(), Trust: held.Trust(),
	}
}

func (i *Installer) arch() string {
	if i.Arch != "" {
		return i.Arch
	}

	return runtime.GOARCH
}

func (i *Installer) Linux(ctx context.Context) error {
	if i.From == "" {
		return ErrNoFrom
	}

	if i.Root == "" && os.Geteuid() != 0 {
		return ErrNoRoot
	}

	userID, userGID, err := i.lookup(i.User)
	if err != nil {
		return fmt.Errorf("%q is not an account on this machine: %w", i.User, err)
	}

	if _, _, err := i.lookup(PartUser); err != nil {
		if err := i.run(ctx, "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent", "--shell", "/usr/sbin/nologin", PartUser); err != nil {
			return fmt.Errorf("the %s account could not be made: %w", PartUser, err)
		}
	}

	held := i.layout()

	for _, dir := range []string{held.Lib(), held.Etc()} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	config, err := state.Setup(held.Config(), i.Xixo, i.Issuer, i.Folders)
	if err != nil {
		return err
	}

	if i.Unsigned && !config.Unsigned() {
		if err := state.AllowUnsigned(held.Config()); err != nil {
			return err
		}

		if config, err = state.LoadConfig(held.Config()); err != nil {
			return err
		}
	}

	if err := update.Write(held.Install(), update.Installed{User: i.User}, 0o644); err != nil {
		return err
	}

	signed, err := i.vouch(config).Served(ctx)
	if err != nil {
		return err
	}

	files, err := signed.Linux(i.arch())
	if err != nil {
		return err
	}

	if sum, err := update.Digest(i.From); err != nil || sum != files[0].SHA256 {
		return ErrNotListed
	}

	staging, err := os.MkdirTemp(held.Lib(), ".install-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging)

	if err := copied(i.From, filepath.Join(staging, files[0].Name), 0o755, 0, 0, false); err != nil {
		return err
	}

	for _, entry := range files[1:] {
		fetched, err := update.Fetch(ctx, i.client(), update.Address(i.Xixo, entry.Name), entry.SHA256, staging)
		if err != nil {
			return fmt.Errorf("%s did not download from %s: %w", entry.Name, i.Xixo, err)
		}

		if err := os.Rename(fetched, filepath.Join(staging, entry.Name)); err != nil {
			return err
		}
	}

	placer := i.placer()

	if err := placer.Keep(signed, files, staging); err != nil {
		return err
	}

	i.retire(ctx)

	if _, err := placer.Render(signed.ID); err != nil {
		return err
	}

	if err := placer.Link(signed.ID); err != nil {
		return err
	}

	if err := placer.Promote(signed.ID); err != nil {
		return err
	}

	if err := i.vouch(config).Accept(signed.Release); err != nil {
		return err
	}

	update.Prune(held.Releases())

	if err := os.MkdirAll(i.path(StateDir), 0o700); err != nil {
		return err
	}

	if err := os.Chown(i.path(StateDir), userID, userGID); err != nil && i.Root == "" {
		return err
	}

	if err := placer.Reload(ctx); err != nil {
		return err
	}

	if err := placer.Enable(ctx); err != nil {
		return err
	}

	packages := &update.Packages{Layout: held, Run: i.Run, Out: i.Out, LookPath: i.LookPath}
	if err := packages.Install(ctx); err != nil {
		fmt.Fprintf(i.out(), "   %s\n", err)
	}

	return nil
}

func (i *Installer) retire(ctx context.Context) {
	held := i.layout()

	for _, stale := range []string{held.Binary() + update.Previous, held.Trust()} {
		if info, err := os.Lstat(stale); err == nil && (info.Mode().IsRegular() || info.IsDir()) {
			os.RemoveAll(stale)
		}
	}

	if info, err := os.Lstat(held.Binary()); err == nil && info.Mode().IsRegular() {
		os.Remove(held.Binary())
	}

	if _, _, err := i.lookup(Updater); err == nil {
		i.run(ctx, "userdel", Updater)
	}
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
	units := []string{"xixo-link", update.UpdatePath, update.UpdateTimer, update.FetchUnit, update.UpdateUnit, update.PackagesUnit}
	for _, part := range parts.Known() {
		units = append(units, "xixo-link-part@"+part+".path", "xixo-link-part@"+part+".service")
	}

	i.run(ctx, "systemctl", append([]string{"disable", "--now", "--quiet"}, units...)...)

	for _, name := range LinuxUnits {
		os.Remove(i.path(Units + "/" + name))
	}

	i.run(ctx, "systemctl", "daemon-reload")

	for _, held := range []string{Bin, Lib, Etc, StateDir, Cache, PartsState, update.Cache, "/var/cache/private/xixo-link-update"} {
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
