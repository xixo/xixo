package install

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/xixo/xixo/link/internal/state"
)

const MacReader = "xixo-mac-reader"

func (i *Installer) home() (string, error) {
	if i.Home != "" {
		return i.Home, nil
	}

	return os.UserHomeDir()
}

func (i *Installer) Support() (string, error) {
	home, err := i.home()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, "Library", "Application Support", "xixo-link"), nil
}

func (i *Installer) Mac(ctx context.Context) error {
	if i.From == "" {
		return ErrNoFrom
	}

	home, err := i.home()
	if err != nil {
		return err
	}

	dir, err := i.Support()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o755); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Join(home, "Library", "LaunchAgents"), 0o755); err != nil {
		return err
	}

	reader := filepath.Join(filepath.Dir(i.From), MacReader)
	if raw, err := i.fetchUpTo(ctx, MacReader, 256<<20); err == nil {
		if err := os.WriteFile(reader, raw, 0o755); err != nil {
			return err
		}
	} else {
		fmt.Fprintln(i.out(), "   The mac reader did not download, so this Mac reads files with the Homebrew programs it has.")
	}

	if i.supervises(ctx, filepath.Join(dir, "bin", "xixo-link")) && i.Stage != nil {
		if _, err := i.Stage(i.From, filepath.Join(dir, "releases")); err != nil {
			return err
		}
	} else {
		os.RemoveAll(filepath.Join(dir, "releases"))

		if err := copied(i.From, filepath.Join(dir, "bin", "xixo-link"), 0o755, 0, 0, false); err != nil {
			return err
		}

		if _, err := os.Stat(reader); err == nil {
			if err := copied(reader, filepath.Join(dir, "bin", MacReader), 0o755, 0, 0, false); err != nil {
				return err
			}
		}
	}

	if _, err := state.Setup(filepath.Join(dir, "config.json"), i.Xixo, i.Issuer, i.Folders); err != nil {
		return err
	}

	plist, err := i.fetch(ctx, Plist)
	if err != nil {
		return err
	}

	agent := strings.ReplaceAll(string(plist), "@HOME@", home)

	return os.WriteFile(filepath.Join(home, "Library", "LaunchAgents", LaunchLabel+".plist"), []byte(agent), 0o644)
}

func (i *Installer) supervises(ctx context.Context, binary string) bool {
	if _, err := os.Stat(binary); err != nil {
		return false
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	out, _ := exec.CommandContext(ctx, binary, "run", "-h").CombinedOutput()

	return strings.Contains(string(out), "-supervised")
}

func (i *Installer) StartMac(ctx context.Context) error {
	home, err := i.home()
	if err != nil {
		return err
	}

	service := fmt.Sprintf("gui/%d/%s", os.Getuid(), LaunchLabel)
	agent := filepath.Join(home, "Library", "LaunchAgents", LaunchLabel+".plist")

	i.run(ctx, "launchctl", "bootout", service)

	for tries := 0; tries < 20; tries++ {
		if err := i.run(ctx, "launchctl", "print", service); err != nil {
			break
		}

		time.Sleep(500 * time.Millisecond)
	}

	var bootstrapped error
	for tries := 0; tries < 10; tries++ {
		if bootstrapped = i.run(ctx, "launchctl", "bootstrap", fmt.Sprintf("gui/%d", os.Getuid()), agent); bootstrapped == nil {
			break
		}

		time.Sleep(time.Second)
	}

	if bootstrapped != nil {
		return fmt.Errorf("macOS did not load the xixo link service. Run the command again: %w", bootstrapped)
	}

	return i.run(ctx, "launchctl", "kickstart", service)
}

func (i *Installer) UninstallMac(ctx context.Context) error {
	home, err := i.home()
	if err != nil {
		return err
	}

	dir, err := i.Support()
	if err != nil {
		return err
	}

	i.run(ctx, "launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), LaunchLabel))
	os.Remove(filepath.Join(home, "Library", "LaunchAgents", LaunchLabel+".plist"))

	for _, held := range []string{dir, filepath.Join(home, "Library", "Caches", "xixo-link")} {
		if err := os.RemoveAll(held); err != nil {
			return err
		}
	}

	return nil
}
