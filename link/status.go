package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/terminal"
)

const (
	launchLabel = "network.xixo.link"
	lookedUpIn  = 20 * time.Second
)

var (
	serviceState = runningHere
	updatesHere  = updatingHere
)

func status(ctx context.Context, configPath, stateDir string, out io.Writer) error {
	config, err := state.LoadConfig(configPath)
	if errors.Is(err, fs.ErrNotExist) {
		return errors.New("xixo link is not set up on this machine. Copy the link-up command from Resources in xixo, and run it here")
	}

	if err != nil {
		return err
	}

	style := terminal.For(out)
	xixo := terminal.Printable(config.Xixo)
	linked, problem := lookup(ctx, config, state.State{Dir: stateDir})

	if linked != nil {
		fmt.Fprintf(out, "%s is linked up with %s.\n\n", style.Bold(linked.Name), xixo)
	} else {
		fmt.Fprintf(out, "This machine is not linked up with %s.\n%s\n\n", xixo, problem)
	}

	row := func(label, value string) {
		fmt.Fprintf(out, "  %-10s %s\n", label, value)
	}

	if linked != nil && linked.URL != "" {
		row("In xixo", linked.URL)
	}

	row("Version", version)
	row("Service", serviceState())
	row("Updates", updates(linked))

	if len(config.Folders) == 0 {
		row("Folders", "none yet. Run the link-up command again with the folders to share.")
	}

	width := 0
	for _, folder := range config.Folders {
		width = max(width, len(folder.Path))
	}

	for at, folder := range config.Folders {
		label := ""
		if at == 0 {
			label = "Folders"
		}

		access := "read only"
		if folder.Writable {
			access = style.Yellow("read and write")
		}

		row(label, fmt.Sprintf("%-*s  %s", width, terminal.Printable(folder.Path), access))
	}

	fmt.Fprintf(out, "\nTo check on xixo link:\n")

	for _, line := range checks() {
		fmt.Fprintf(out, "  %s\n", line)
	}

	return nil
}

func lookup(ctx context.Context, config *state.Config, held state.State) (*link.Linked, string) {
	_, err := held.Registration()

	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, "Run the link-up command from Resources in xixo to link it up."
	case errors.Is(err, fs.ErrPermission):
		return nil, "Only the account xixo link runs as can read its keys. Run xixo-link status as that account, or with sudo."
	case err != nil:
		return nil, err.Error()
	}

	ctx, cancel := context.WithTimeout(ctx, lookedUpIn)
	defer cancel()

	linked, err := link.Lookup(ctx, config, held)

	switch {
	case err == nil:
		return linked, ""
	case errors.Is(err, link.ErrUnknown), errors.Is(err, link.ErrRevoked):
		return nil, "xixo no longer knows this machine. Run the link-up command again to link it up."
	}

	return nil, "xixo did not say what it calls this machine: " + err.Error()
}

func updates(linked *link.Linked) string {
	switch {
	case !updatesHere():
		return "off. Run the link-up command again to turn them on."
	case linked != nil && !linked.Updates:
		return "paused in xixo. Turn on Update xixo link automatically on the machine's card."
	}

	return "automatic"
}

func checks() []string {
	if runtime.GOOS == "darwin" {
		return []string{
			fmt.Sprintf("launchctl print gui/%d/%s", os.Getuid(), launchLabel),
			"tail -f ~/Library/Logs/xixo-link.log",
		}
	}

	return []string{"systemctl status xixo-link", "journalctl -u xixo-link -f"}
}

func runningHere() string {
	if runtime.GOOS == "darwin" {
		said, err := exec.Command("launchctl", "print", fmt.Sprintf("gui/%d/%s", os.Getuid(), launchLabel)).Output()
		if err != nil {
			return "not loaded. Run the link-up command again to start it."
		}

		if bytes.Contains(said, []byte("state = running")) {
			return "running"
		}

		return "stopped"
	}

	said, _ := exec.Command("systemctl", "is-active", "xixo-link").Output()

	switch strings.TrimSpace(string(said)) {
	case "active":
		return "running"
	case "activating", "reloading":
		return "starting"
	case "deactivating":
		return "stopping"
	case "failed":
		return "stopped after an error. See why with journalctl -u xixo-link -n 50"
	case "inactive":
		return "stopped"
	}

	return "not installed. Run the link-up command again to install it."
}

func updatingHere() bool {
	if runtime.GOOS == "darwin" {
		home, err := os.UserHomeDir()
		if err != nil {
			return false
		}

		agent, err := os.ReadFile(filepath.Join(home, "Library", "LaunchAgents", launchLabel+".plist"))

		return err == nil && bytes.Contains(agent, []byte("<string>self</string>"))
	}

	return exec.Command("systemctl", "is-enabled", "--quiet", "xixo-link-update.path").Run() == nil
}
