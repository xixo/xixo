package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/xixo/xixo/link/internal/dial"
	"github.com/xixo/xixo/link/internal/install"
	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/update"
)

const (
	modeSystemd    = "systemd"
	modeSelf       = "self"
	updateRequests = "/run/xixo-link"
	updateResults  = "/run/xixo-link-update"
	updateCache    = update.Cache
	replacedEvery  = 5 * time.Second
)

var (
	errRestart     = errors.New("xixo link restarts into a new version")
	errSystemdOnly = errors.New("--updates systemd works only when systemd runs xixo link on Linux")
	errSelfOnly    = errors.New("--updates self works only on macOS")
)

type exitStatus int

func (e exitStatus) Error() string {
	return fmt.Sprintf("exit status %d", int(e))
}

func runtimeDir(fallback string) string {
	held, _, _ := strings.Cut(os.Getenv("RUNTIME_DIRECTORY"), ":")
	if held == "" {
		return fallback
	}

	return held
}

func executable() (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", err
	}

	return filepath.EvalSymlinks(self)
}

func updater(ctx context.Context, mode, releases, stateDir string, config *state.Config, running *link.Link, restart func()) link.Updater {
	switch mode {
	case modeSystemd:
		if self, err := installedBinary(); err == nil {
			go func() {
				if update.Replaced(ctx, self, replacedEvery) {
					restart()
				}
			}()
		}

		return &update.Requester{Dir: runtimeDir(updateRequests), Results: updateResults, Self: running.Identity}
	case modeSelf:
		if releases == "" {
			return nil
		}

		held := &update.Stager{
			Xixo: config.Xixo, Releases: releases, State: stateDir, Self: running.Identity,
			Client: dial.Fetcher(), Restart: restart, Vouch: vouchFor(config, filepath.Dir(releases)),
			Supervisor: filepath.Join(filepath.Dir(releases), "bin", "xixo-link"), Relaunch: relaunch,
		}

		if home, err := os.UserHomeDir(); err == nil {
			held.Home = home
			held.Agent = filepath.Join(home, "Library", "LaunchAgents", install.LaunchLabel+".plist")
		}

		return held
	}

	return nil
}

func supervise(ctx context.Context, args []string, stateDir string) error {
	self, err := executable()
	if err != nil {
		return err
	}

	held := &update.Supervisor{
		Self:     self,
		Releases: filepath.Join(filepath.Dir(filepath.Dir(self)), "releases"),
		State:    stateDir,
		Args:     args,
		Log:      slog.New(slog.NewTextHandler(os.Stderr, nil)),
	}

	if status := held.Run(ctx); status != 0 {
		return exitStatus(status)
	}

	return nil
}

func installedBinary() (string, error) {
	if info, err := os.Lstat(update.Layout{}.Binary()); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return update.Layout{}.Binary(), nil
	}

	return executable()
}

func updated(ctx context.Context, configPath, requests, results string) error {
	config, err := state.LoadConfig(configPath)
	if err != nil {
		return err
	}

	layout := update.Layout{}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	running, _ := strconv.ParseInt(serial, 10, 64)

	held := &update.Updater{
		Placer:   update.Placer{Layout: layout, Out: os.Stderr, Log: log},
		Requests: requests,
		Results:  results,
		Vouch: &update.Vouch{
			Offline: true, Mirror: filepath.Join(update.Cache, update.MirrorDir), Trust: layout.Trust(),
			Floor: layout.Floor(), Running: running, Unsigned: config.Unsigned(),
		},
	}

	return held.Apply(ctx)
}

func fetched(ctx context.Context, configPath, requests, cache string) error {
	config, err := state.LoadConfig(configPath)
	if err != nil {
		return err
	}

	running, _ := strconv.ParseInt(serial, 10, 64)

	held := &update.Fetcher{
		Xixo:     config.Xixo,
		Requests: requests,
		Cache:    cache,
		Client:   dial.Fetcher(),
		Log:      slog.New(slog.NewTextHandler(os.Stderr, nil)),
		Vouch: &update.Vouch{
			Xixo: config.Xixo, Client: dial.Fetcher(), Mirror: filepath.Join(cache, update.MirrorDir), Trust: filepath.Join(cache, update.TrustDir),
			Floor: update.Layout{}.Floor(), Running: running, Unsigned: config.Unsigned(),
		},
	}

	return held.Fetch(ctx)
}

func packaged(ctx context.Context, stdout io.Writer) error {
	return (&update.Packages{Out: stdout}).Install(ctx)
}

func vouchFor(config *state.Config, root string) *update.Vouch {
	running, _ := strconv.ParseInt(serial, 10, 64)

	return &update.Vouch{
		Xixo: config.Xixo, Client: dial.Fetcher(), Unsigned: config.Unsigned(), Running: running,
		Floor: filepath.Join(root, update.FloorFile), Trust: filepath.Join(root, update.TrustDir),
	}
}

func relaunch(_ context.Context) error {
	self, err := executable()
	if err != nil {
		return err
	}

	command := exec.Command(self, "relaunch")
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	return command.Start()
}

func relaunched(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Second):
	}

	return (&install.Installer{Out: os.Stderr}).StartMac(ctx)
}
