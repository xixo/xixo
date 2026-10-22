package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/xixo/xixo/link/internal/registry"
	"github.com/xixo/xixo/link/internal/updates"
	"github.com/xixo/xixo/link/internal/verify"
)

var version = "dev"

const usage = `xixo-updater keeps a xixo server on builds CI signed.

  xixo-updater watch    check the registry and ask the gate to update (has network, no Docker)
  xixo-updater gate     pull, swap, and roll back containers (has Docker, no network)
  xixo-updater ready    exit 0 once the gate holds a build of everything it keeps
  xixo-updater idle     exit 0 when the gate is not pulling, swapping, or rolling back
  xixo-updater version  print the version

Settings come from the environment:

  XIXO_UPDATES_CHANNEL  main or releases (releases)
  XIXO_UPDATES_KINDS    what the gate keeps: masks, xixo, xixo-link (xixo,xixo-link)
  XIXO_UPDATES_SOCKET   the gate's socket (/run/xixo-updates/gate/gate.sock)
  XIXO_UPDATES_MIRROR   sigstore's TUF files, written by watch, read by gate (/run/xixo-updates/tuf)
  XIXO_UPDATES_STATE    where watch keeps status.json and events.jsonl (/var/lib/xixo-updates/state)
  XIXO_UPDATES_REQUEST  the request.json xixo writes for watch to read (/run/xixo-updates/requests/request.json)
  XIXO_UPDATES_CACHE    the TUF cache each one keeps for itself (/var/lib/xixo-updates/cache)
  DOCKER_SOCKET         the Docker socket the gate uses (/var/run/docker.sock)
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := command(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "xixo-updater:", err)
		os.Exit(1)
	}
}

func setting(name, fallback string) string {
	if held := os.Getenv(name); held != "" {
		return held
	}

	return fallback
}

func command(ctx context.Context, args []string, stdout io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stdout, usage)
		return errors.New("name a command")
	}

	socket := setting("XIXO_UPDATES_SOCKET", "/run/xixo-updates/gate/gate.sock")
	mirror := setting("XIXO_UPDATES_MIRROR", "/run/xixo-updates/tuf")
	cache := setting("XIXO_UPDATES_CACHE", "/var/lib/xixo-updates/cache")
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil)).With("updater", args[0], "version", version)

	switch args[0] {
	case "version":
		fmt.Fprintln(stdout, version)
		return nil
	case "idle":
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()

		return updates.Dial(socket).Idle(ctx)
	case "ready":
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()

		return updates.Dial(socket).Ready(ctx)
	case "gate":
		return gate(ctx, log, socket, mirror, cache)
	case "watch":
		return watch(ctx, log, socket, mirror, cache)
	default:
		fmt.Fprint(stdout, usage)
		return fmt.Errorf("%q is not a command", args[0])
	}
}

func kinds() ([]updates.Kind, error) {
	held := []updates.Kind{}

	for _, name := range strings.Split(setting("XIXO_UPDATES_KINDS", "xixo,xixo-link"), ",") {
		kind, err := updates.Named(strings.TrimSpace(name))
		if err != nil {
			return nil, err
		}

		held = append(held, kind)
	}

	return held, nil
}

func gate(ctx context.Context, log *slog.Logger, socket, mirror, cache string) error {
	kept, err := kinds()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(socket), 0o755); err != nil {
		return err
	}

	listener, err := updates.Listen(socket)
	if err != nil {
		return err
	}

	held := &updates.Gate{
		Docker: updates.Socket(setting("DOCKER_SOCKET", "/var/run/docker.sock")),
		Kinds:  kept,
		Log:    log,
		Checker: func() (*verify.Checker, error) {
			trusted, err := verify.Mirrored(mirror, filepath.Join(cache, "gate"))
			if err != nil {
				return nil, err
			}

			return &verify.Checker{Trusted: trusted}, nil
		},
	}

	names := []string{}
	for _, kind := range kept {
		names = append(names, kind.Name)
	}

	log.Info("the gate is listening", "socket", socket, "keeps", strings.Join(names, ","))

	return updates.Serve(ctx, listener, held.Handler())
}

func watch(ctx context.Context, log *slog.Logger, socket, mirror, cache string) error {
	channel := setting("XIXO_UPDATES_CHANNEL", updates.Releases)
	if channel != updates.Main && channel != updates.Releases {
		return fmt.Errorf("XIXO_UPDATES_CHANNEL is %q: name main or releases", channel)
	}

	book, err := updates.Open(setting("XIXO_UPDATES_STATE", "/var/lib/xixo-updates/state"))
	if err != nil {
		return err
	}

	watcher := &updates.Watcher{
		Gate:     updates.Dial(socket),
		Registry: &registry.Client{},
		Channel:  channel,
		Book:     book,
		Log:      log,
		Checker: func() (*verify.Checker, error) {
			trusted, err := verify.Live(mirror, filepath.Join(cache, "watch"))
			if err != nil {
				return nil, err
			}

			return &verify.Checker{Trusted: trusted}, nil
		},
	}

	go book.Requests(ctx, setting("XIXO_UPDATES_REQUEST", "/run/xixo-updates/requests/request.json"), 0)

	log.Info("watching for updates", "channel", book.Channel(channel))

	return watcher.Run(ctx)
}
