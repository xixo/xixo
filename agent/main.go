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
	"strings"
	"syscall"

	"github.com/xixo/xixo/agent/internal/agent"
	_ "github.com/xixo/xixo/agent/internal/extract/documents"
	_ "github.com/xixo/xixo/agent/internal/extract/plain"
	_ "github.com/xixo/xixo/agent/internal/extract/rich"
	"github.com/xixo/xixo/agent/internal/folders"
	"github.com/xixo/xixo/agent/internal/machine"
	"github.com/xixo/xixo/agent/internal/state"
)

var version = "dev"

const revoked = 78

const usage = `xixo-agent connects this machine to xixo.

  xixo-agent enroll --token - [--name NAME] [--config PATH] [--state DIR]
  xixo-agent run [--config PATH] [--state DIR]
  xixo-agent version
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := command(ctx, os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "xixo-agent:", err)

		if errors.Is(err, agent.ErrRevoked) {
			os.Exit(revoked)
		}

		os.Exit(1)
	}
}

func command(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stdout, usage)

		return errors.New("name a command")
	}

	set := flag.NewFlagSet("xixo-agent "+args[0], flag.ContinueOnError)
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

		registered, err := agent.Enroll(ctx, config, state.State{Dir: *stateDir}, held, strings.TrimSpace(named))
		if err != nil {
			return err
		}

		fmt.Fprintln(stdout, registered.ClientID)

		return nil
	case "run":
		if err := set.Parse(args[1:]); err != nil {
			return err
		}

		config, err := state.LoadConfig(*configPath)
		if err != nil {
			return err
		}

		client, dpop, err := agent.Client(ctx, config, state.State{Dir: *stateDir})
		if err != nil {
			return err
		}

		running := &agent.Agent{
			Xixo:    config.Xixo,
			Version: version,
			Folders: folders.New(config.Folders),
			Machine: machine.New(),
			Tokens:  agent.Tokens(client, config),
			DPoP:    dpop,
			Log:     slog.New(slog.NewTextHandler(os.Stderr, nil)),
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
