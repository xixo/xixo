package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	osuser "os/user"
	"runtime"
	"strings"

	"github.com/xixo/xixo/link/internal/dial"
	"github.com/xixo/xixo/link/internal/install"
	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/person"
	"github.com/xixo/xixo/link/internal/state"
)

var sshProgram = "ssh"

func overSSH(ctx context.Context, host, command string, stdin io.Reader, tty bool) ([]byte, error) {
	args := []string{}
	if tty {
		args = append(args, "-t")
	}

	args = append(args, "--", host, command)
	held := exec.CommandContext(ctx, sshProgram, args...)
	out := &bytes.Buffer{}

	if tty {
		held.Stdin = os.Stdin
		held.Stdout = os.Stdout
		held.Stderr = os.Stderr
	} else {
		held.Stdin = stdin
		held.Stdout = out
		held.Stderr = os.Stderr
	}

	err := held.Run()

	return out.Bytes(), err
}

func installer(xixo, issuer, user, from string, folders []string, out io.Writer) *install.Installer {
	return &install.Installer{
		Xixo: xixo, Issuer: issuer, User: user, From: from, Folders: folders, Unsigned: serial == "0",
		Client: dial.Client(dial.Answered), Out: out, Stage: stage,
	}
}

func installed(ctx context.Context, held *install.Installer) error {
	if held.User == "" {
		current, err := osuser.Current()
		if err != nil {
			return err
		}

		held.User = current.Username
	}

	if runtime.GOOS == "darwin" {
		return held.Mac(ctx)
	}

	return held.Linux(ctx)
}

func started(ctx context.Context, held *install.Installer) error {
	if runtime.GOOS == "darwin" {
		return held.StartMac(ctx)
	}

	return held.StartLinux(ctx)
}

func uninstalled(ctx context.Context, held *install.Installer) error {
	if runtime.GOOS == "darwin" {
		return held.UninstallMac(ctx)
	}

	return held.UninstallLinux(ctx)
}

func loginStore() person.Store {
	return person.Store{Path: person.DefaultPath()}
}

func chosenXixo(flag string) (string, error) {
	if flag != "" {
		return strings.TrimSuffix(flag, "/"), nil
	}

	return loginStore().Only()
}

func personToken(ctx context.Context, xixo string) (string, error) {
	return loginStore().Token(ctx, dial.Client(dial.Answered), xixo)
}

func joined(ctx context.Context, configPath, stateDir string, stdin io.Reader, stdout io.Writer) error {
	config, err := state.LoadConfig(configPath)
	if err != nil {
		return err
	}

	joining, err := link.ReadJoining(stdin)
	if err != nil {
		return err
	}

	_, err = link.Join(ctx, config, state.State{Dir: stateDir}, joining, stdout)

	return err
}

func linkedJSON(ctx context.Context, configPath, stateDir string, stdout io.Writer) error {
	config, err := state.LoadConfig(configPath)
	if err != nil {
		return err
	}

	linked, err := link.Lookup(ctx, config, state.State{Dir: stateDir})
	if errors.Is(err, link.ErrUnknown) {
		return errors.New("xixo knows no machine linked as this one")
	}

	if err != nil {
		return err
	}

	fmt.Fprintf(stdout, "{\"name\":%q,\"key\":%q,\"url\":%q}\n", linked.Name, linked.Key, linked.URL)

	return nil
}
