package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/terminal"
)

type about struct {
	name     string
	takes    string
	says     string
	everyday bool
}

var commands = []about{
	{"status", "", "Show this machine's name in xixo, its folders, and whether xixo link is running.", true},
	{"version", "", "Print the version of xixo link.", true},
	{"help", "", "Show this list.", true},
	{"setup", "--xixo URL --issuer URL [FOLDER[:rw] ...]", "Save the address of xixo and the folders to share.", false},
	{"unit", "--template PATH [--user NAME]", "Print the systemd service for this machine.", false},
	{"up", "", "Link up this machine. It waits until an administrator approves it in xixo.", false},
	{"describe", "[FOLDER[:rw] ...]", "Print what this machine is, as JSON: its system, processor, GPUs, disks, readers, and folders.", false},
	{"stage", "[--releases DIR]", "Install this build as an update on a Mac, so Full Disk Access stays.", false},
	{"enroll", "--token - [--name NAME]", "Enroll with a token, for the xixo link beside the server.", false},
	{"run", "[--updates systemd|self]", "Connect to xixo and serve it. The service runs this.", false},
	{"update", "", "Install the build xixo names. The Linux updater runs this.", false},
	{"part", "NAME --releases DIR --state DIR --wanted FILE [--status FILE]", "Run a part, such as models, while xixo wants it. The part's service runs this.", false},
	{"readable", "FOLDER", "Check that xixo link may read a folder.", false},
}

func help(out io.Writer) {
	style := terminal.For(out)

	fmt.Fprintln(out, "xixo link connects this machine to xixo, so xixo can search and read the folders it shares.")
	fmt.Fprintln(out)
	fmt.Fprintln(out, style.Bold("Commands:"))
	listed(out, true)
	fmt.Fprintln(out)
	fmt.Fprintln(out, style.Bold("The install command and the services run these:"))
	listed(out, false)
	fmt.Fprintln(out)
	fmt.Fprintln(out, "Run xixo-link COMMAND -h to see what a command takes.")
	fmt.Fprintln(out)
	fmt.Fprintln(out, "To share other folders, run the link-up command again with the folders to share.")
	fmt.Fprintln(out, "End a folder with :rw to let xixo write into it:")

	if config, err := state.LoadConfig(state.DefaultConfig); err == nil {
		fmt.Fprintf(out, "  curl -fsSL %s/link.sh | sh -s -- /srv/media /srv/inbox:rw\n", terminal.Printable(config.Xixo))
	} else {
		fmt.Fprintln(out, "  curl -fsSL https://xixo.example.com/link.sh | sh -s -- /srv/media /srv/inbox:rw")
	}
}

func listed(out io.Writer, everyday bool) {
	for _, held := range commands {
		if held.everyday == everyday {
			fmt.Fprintf(out, "  %-10s %s\n", held.name, held.says)
		}
	}
}

func parsed(set *flag.FlagSet, args []string, out io.Writer) error {
	err := set.Parse(args[1:])
	if err == nil {
		return nil
	}

	if !errors.Is(err, flag.ErrHelp) {
		return fmt.Errorf("%w. Run xixo-link %s -h to see what it takes", err, args[0])
	}

	for _, held := range commands {
		if held.name == args[0] {
			fmt.Fprintln(out, strings.TrimSpace("Usage: xixo-link "+held.name+" "+held.takes))
			fmt.Fprintln(out)
			fmt.Fprintln(out, held.says)
		}
	}

	fmt.Fprintln(out)
	fmt.Fprintln(out, "Flags:")
	set.SetOutput(out)
	set.PrintDefaults()

	return exitStatus(0)
}
