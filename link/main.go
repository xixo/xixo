package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	osuser "os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
	_ "github.com/xixo/xixo/link/internal/extract/documents"
	_ "github.com/xixo/xixo/link/internal/extract/plain"
	_ "github.com/xixo/xixo/link/internal/extract/rich"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/update"
)

var version = "dev"

const revoked = 78

const (
	accessGranted      = 75
	accessCheckedEvery = 15 * time.Second
)

var revokedStatus = revoked

const usage = `xixo-link connects this machine to xixo.

  xixo-link setup --xixo URL --issuer URL [--config PATH] [FOLDER[:rw] ...]
  xixo-link unit --template PATH [--user NAME] [--config PATH]
  xixo-link up [--config PATH] [--state DIR]
  xixo-link enroll --token - [--name NAME] [--config PATH] [--state DIR]
  xixo-link run [--config PATH] [--state DIR] [--revoked-status N] [--updates systemd|self]
  xixo-link update [--config PATH] [--requests DIR] [--results DIR]
  xixo-link version
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := command(ctx, os.Args[1:], os.Stdin, os.Stdout); err != nil {
		var held exitStatus
		if errors.As(err, &held) {
			os.Exit(int(held))
		}

		fmt.Fprintln(os.Stderr, "xixo-link:", err)

		if errors.Is(err, link.ErrRevoked) {
			os.Exit(revokedStatus)
		}

		os.Exit(1)
	}
}

func command(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stdout, usage)

		return errors.New("name a command")
	}

	set := flag.NewFlagSet("xixo-link "+args[0], flag.ContinueOnError)
	configPath := set.String("config", state.DefaultConfig, "the config file")
	stateDir := set.String("state", state.DefaultState, "the directory holding this machine's keys")

	switch args[0] {
	case "version":
		fmt.Fprintln(stdout, version)

		return nil
	case "enroll":
		token := set.String("token", "", "the enrollment token, or - to read it from standard input")
		name := set.String("name", "", "the name masks shows for this machine")

		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		config, err := state.LoadConfig(*configPath)
		if err != nil {
			return err
		}

		held, err := given(*token, stdin)
		if err != nil {
			return err
		}

		if held == "" {
			held = os.Getenv("XIXO_ENROLLMENT_TOKEN")
		}

		named := *name
		if named == "" {
			named, _ = os.Hostname()
		}

		registered, err := link.Enroll(ctx, config, state.State{Dir: *stateDir}, held, strings.TrimSpace(named))
		if err != nil {
			return err
		}

		fmt.Fprintln(stdout, registered.ClientID)

		return nil
	case "setup":
		xixo := set.String("xixo", "", "the address of xixo")
		issuer := set.String("issuer", "", "the address of the masks issuer xixo link enrolls with")

		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		config, err := state.Setup(*configPath, *xixo, *issuer, set.Args())
		if err != nil {
			return err
		}

		fmt.Fprintln(stdout, sharing(config))

		return nil
	case "unit":
		template := set.String("template", "", "the service template xixo hands out")
		user := set.String("user", "", "the account xixo link runs as, by default this one")

		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		config, err := state.LoadConfig(*configPath)
		if err != nil {
			return err
		}

		read, err := os.ReadFile(*template)
		if err != nil {
			return err
		}

		named := *user
		if named == "" {
			current, err := osuser.Current()
			if err != nil {
				return err
			}

			named = current.Username
		}

		written, err := state.Unit(string(read), named, config.Folders)
		if err != nil {
			return err
		}

		fmt.Fprint(stdout, written)

		return nil
	case "up":
		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		config, err := state.LoadConfig(*configPath)
		if err != nil {
			return err
		}

		return link.Up(ctx, config, state.State{Dir: *stateDir}, version, stdout)
	case "update":
		requests := set.String("requests", updateRequests, "the directory xixo link leaves update requests in")
		results := set.String("results", runtimeDir(updateResults), "the directory this command leaves its result in")

		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		return updated(ctx, *configPath, *requests, *results)
	case "run":
		stopped := set.Int("revoked-status", revoked, "the exit status when this machine was unenrolled")
		updates := set.String("updates", "", "how xixo link updates itself: systemd, self, or not at all when empty")
		supervised := set.Bool("supervised", false, "set by the process that runs xixo link and swaps in new versions")
		releases := set.String("releases", "", "the directory that holds the versions xixo link updated to")

		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		revokedStatus = *stopped

		switch *updates {
		case "", modeSystemd:
		case modeSelf:
			if !*supervised {
				return supervise(ctx, args[1:], *stateDir)
			}
		default:
			return fmt.Errorf("--updates takes %s or %s, not %q", modeSystemd, modeSelf, *updates)
		}

		searchPath()

		config, err := state.LoadConfig(*configPath)
		if err != nil {
			return err
		}

		client, dpop, err := link.Client(ctx, config, state.State{Dir: *stateDir})
		if err != nil {
			return err
		}

		shared := folders.New(config.Folders)
		shared.Pin()

		run, notices := runner(config)

		running := &link.Link{
			Xixo:              config.Xixo,
			Version:           version,
			Folders:           shared,
			Machine:           machine.New(),
			Tokens:            link.Tokens(client, config),
			DPoP:              dpop,
			Log:               slog.New(slog.NewTextHandler(os.Stderr, nil)),
			Work:              workDir(),
			Runner:            run,
			Notices:           notices,
			Lend:              config.LendCeiling(),
			ExtractsForOthers: config.OthersCeiling(),
			Tools:             config.ToolCeiling(),
		}

		ctx, restart := context.WithCancelCause(ctx)
		defer restart(nil)

		running.Identity = update.Identify(version)
		running.Updates = updater(ctx, *updates, *releases, *stateDir, config, running, func() { restart(errRestart) })

		if runtime.GOOS == "darwin" {
			go awaitAccess(ctx, shared, running.Log)
		}

		err = running.Run(ctx)
		if errors.Is(context.Cause(ctx), errRestart) {
			running.Log.Info("xixo link restarts into its new version")

			return exitStatus(update.Restart)
		}

		if errors.Is(err, context.Canceled) {
			return nil
		}

		return err
	case "readable":
		if len(args) != 2 {
			return errors.New("readable takes one folder")
		}

		return readable(args[1])
	default:
		fmt.Fprint(stdout, usage)

		return fmt.Errorf("%q is not a command", args[0])
	}
}

func readable(folder string) error {
	dir, err := os.Open(folder)
	if err != nil {
		return err
	}
	defer dir.Close()

	if _, err := dir.ReadDir(1); err != nil && !errors.Is(err, io.EOF) {
		return err
	}

	return nil
}

func awaitAccess(ctx context.Context, shared *folders.Folders, log *slog.Logger) {
	self, err := os.Executable()
	if err != nil {
		return
	}

	ticker := time.NewTicker(accessCheckedEvery)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		for folder, err := range shared.Unreadable() {
			if !errors.Is(err, fs.ErrPermission) {
				continue
			}

			if exec.CommandContext(ctx, self, "readable", folder).Run() == nil {
				log.Info("macOS now lets xixo link read a shared folder, so it restarts to read it", "folder", folder)
				os.Exit(accessGranted)
			}
		}
	}
}

func given(value string, stdin io.Reader) (string, error) {
	if value != "-" {
		return value, nil
	}

	read, err := io.ReadAll(io.LimitReader(stdin, 4096))

	return string(read), err
}

func runner(config *state.Config) (extract.Runner, []string) {
	if runtime.GOOS != "darwin" {
		return extract.Limited{}, nil
	}

	confine, err := extract.Sandbox()
	if err == nil {
		return extract.Limited{Confine: confine}, nil
	}

	if config.ExtractUnsandboxed {
		return extract.Limited{}, []string{"sandbox-exec is missing, so extraction programs run unsandboxed: the config sets extract_unsandboxed"}
	}

	return extract.Limited{Refused: extract.ErrUnconfined}, []string{"sandbox-exec is missing, so xixo link runs no extraction programs and offers only the extractors that need none"}
}

func searchPath() {
	held := filepath.SplitList(os.Getenv("PATH"))

	for _, dir := range state.SearchPath {
		if !slices.Contains(held, dir) {
			held = append(held, dir)
		}
	}

	os.Setenv("PATH", strings.Join(held, string(os.PathListSeparator)))
}

func workDir() string {
	cache, _, _ := strings.Cut(os.Getenv("CACHE_DIRECTORY"), ":")
	if cache == "" {
		cache = state.DefaultCache
	}

	if cache == "" {
		return os.TempDir()
	}

	work := filepath.Join(cache, "work")
	os.RemoveAll(work)

	if err := os.MkdirAll(work, 0o700); err != nil {
		return os.TempDir()
	}

	return work
}

func sharing(config *state.Config) string {
	if len(config.Folders) == 0 {
		return "Shares no folders yet."
	}

	paths := make([]string, 0, len(config.Folders))
	for _, folder := range config.Folders {
		paths = append(paths, folder.Path)
	}

	if len(paths) == 1 {
		return "Shares " + paths[0] + "."
	}

	return "Shares " + strings.Join(paths[:len(paths)-1], ", ") + " and " + paths[len(paths)-1] + "."
}
