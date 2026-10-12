package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"

	"github.com/xixo/xixo/link/internal/extract"
	_ "github.com/xixo/xixo/link/internal/extract/documents"
	_ "github.com/xixo/xixo/link/internal/extract/plain"
	_ "github.com/xixo/xixo/link/internal/extract/rich"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/state"
)

var version = "dev"

const revoked = 78

var revokedStatus = revoked

const usage = `xixo-link connects this machine to xixo.

  xixo-link enroll --token - [--name NAME] [--config PATH] [--state DIR]
  xixo-link run [--config PATH] [--state DIR] [--revoked-status N]
  xixo-link version
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := command(ctx, os.Args[1:], os.Stdin, os.Stdout); err != nil {
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

		held := *token
		if held == "-" {
			read, err := io.ReadAll(io.LimitReader(stdin, 4096))
			if err != nil {
				return err
			}

			held = string(read)
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
	case "run":
		stopped := set.Int("revoked-status", revoked, "the exit status when this machine was unenrolled")

		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		revokedStatus = *stopped
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
			Lend:              config.Lend,
			ExtractsForOthers: config.ExtractsForOthers,
			Tools:             config.Tools,
		}

		err = running.Run(ctx)
		if errors.Is(err, context.Canceled) {
			return nil
		}

		return err
	default:
		fmt.Fprint(stdout, usage)

		return fmt.Errorf("%q is not a command", args[0])
	}
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
