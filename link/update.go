package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/xixo/xixo/link/internal/dial"
	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/update"
)

const (
	modeSystemd    = "systemd"
	modeSelf       = "self"
	updateRequests = "/run/xixo-link"
	updateResults  = "/run/xixo-link-update"
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
		if self, err := executable(); err == nil {
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

		return &update.Stager{
			Xixo: config.Xixo, Releases: releases, State: stateDir, Self: running.Identity,
			Client: dial.Fetcher(), Restart: restart,
		}
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

func updated(ctx context.Context, configPath, requests, results string) error {
	config, err := state.LoadConfig(configPath)
	if err != nil {
		return err
	}

	self, err := executable()
	if err != nil {
		return err
	}

	held := &update.Updater{
		Xixo:     config.Xixo,
		Requests: requests,
		Results:  results,
		Binary:   self,
		Build:    update.BuildFor(runtime.GOOS, runtime.GOARCH),
		Client:   dial.Fetcher(),
		Log:      slog.New(slog.NewTextHandler(os.Stderr, nil)),
	}

	return held.Apply(ctx)
}
