package main

import (
	"context"
	"encoding/json"
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

	"github.com/xixo/xixo/link/internal/dial"
	"github.com/xixo/xixo/link/internal/digests"
	"github.com/xixo/xixo/link/internal/extract"
	_ "github.com/xixo/xixo/link/internal/extract/documents"
	_ "github.com/xixo/xixo/link/internal/extract/plain"
	_ "github.com/xixo/xixo/link/internal/extract/rich"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/link"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/parts"
	"github.com/xixo/xixo/link/internal/person"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/terminal"
	"github.com/xixo/xixo/link/internal/update"
)

var (
	version = "dev"
	serial  = "0"
)

const (
	revoked     = 78
	interrupted = update.Interrupted
)

const (
	accessGranted      = 75
	accessCheckedEvery = 15 * time.Second
)

var revokedStatus = revoked

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := command(ctx, os.Args[1:], os.Stdin, os.Stdout); err != nil {
		var held exitStatus
		if errors.As(err, &held) {
			os.Exit(int(held))
		}

		if errors.Is(err, context.Canceled) {
			os.Exit(interrupted)
		}

		fmt.Fprintf(os.Stderr, "%s %s\n", terminal.For(os.Stderr).Red("Error:"), sentence(err.Error()))

		if errors.Is(err, link.ErrRevoked) {
			os.Exit(revokedStatus)
		}

		os.Exit(1)
	}
}

func command(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 || slices.Contains([]string{"help", "-h", "-help", "--help"}, args[0]) {
		help(stdout)

		return nil
	}

	set := flag.NewFlagSet("xixo-link "+args[0], flag.ContinueOnError)
	set.SetOutput(io.Discard)
	configPath := set.String("config", state.DefaultConfig, "the config file")
	stateDir := set.String("state", state.DefaultState, "the directory holding this machine's keys")

	parse := func() error {
		return parsed(set, args, stdout)
	}

	switch args[0] {
	case "version":
		fmt.Fprintln(stdout, version)

		return nil
	case "status":
		if err := parse(); err != nil {
			return err
		}

		return status(ctx, *configPath, *stateDir, stdout)
	case "stage":
		releases := set.String("releases", filepath.Join(filepath.Dir(state.DefaultConfig), "releases"), "the directory that holds the versions the launch agent runs")

		if err := parse(); err != nil {
			return err
		}

		return staged(*releases)
	case "enroll":
		token := set.String("token", "", "the enrollment token, or - to read it from standard input")
		name := set.String("name", "", "the name masks shows for this machine")

		if err := parse(); err != nil {
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

		if err := parse(); err != nil {
			return err
		}

		_, err := state.Setup(*configPath, *xixo, *issuer, set.Args())

		return err
	case "unit":
		template := set.String("template", "", "the service template xixo hands out")
		user := set.String("user", "", "the account xixo link runs as, by default this one")

		if err := parse(); err != nil {
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
		if err := parse(); err != nil {
			return err
		}

		config, err := state.LoadConfig(*configPath)
		if err != nil {
			return err
		}

		searchPath()
		run, _ := runner()

		return link.Up(ctx, config, state.State{Dir: *stateDir}, version, extract.AvailableTo(run), stdout)
	case "describe":
		if err := parse(); err != nil {
			return err
		}

		config := &state.Config{}
		if loaded, err := state.LoadConfig(*configPath); err == nil {
			config = loaded
		}

		if set.NArg() > 0 {
			config.Folders = nil

			for _, arg := range set.Args() {
				folder, err := state.Folder(arg)
				if err != nil {
					return err
				}

				config.Folders = append(config.Folders, folder)
			}
		}

		searchPath()
		run, _ := runner()
		described, err := json.MarshalIndent(link.Described(ctx, config, version, extract.AvailableTo(run)), "", "  ")
		if err != nil {
			return err
		}

		fmt.Fprintln(stdout, string(described))

		return nil
	case "update":
		requests := set.String("requests", updateRequests, "the directory xixo link leaves update requests in")
		results := set.String("results", runtimeDir(updateResults), "the directory this command leaves its result in")

		if err := parse(); err != nil {
			return err
		}

		return updated(ctx, *configPath, *requests, *results)
	case "fetch":
		requests := set.String("requests", updateRequests, "the directory xixo link leaves update requests in")
		cache := set.String("cache", cacheDirOr(updateCache), "the directory this command downloads a release into")

		if err := parse(); err != nil {
			return err
		}

		return fetched(ctx, *configPath, *requests, *cache)
	case "packages":
		if err := parse(); err != nil {
			return err
		}

		return packaged(ctx, stdout)
	case "run":
		stopped := set.Int("revoked-status", revoked, "the exit status when this machine was unenrolled")
		updates := set.String("updates", "", "how xixo link updates itself: systemd, self, or not at all when empty")
		supervised := set.Bool("supervised", false, "set by the process that runs xixo link and swaps in new versions")
		releases := set.String("releases", "", "the directory that holds the versions xixo link updated to")

		if err := parse(); err != nil {
			return err
		}

		revokedStatus = *stopped

		switch *updates {
		case "":
		case modeSystemd:
			if runtime.GOOS != "linux" || os.Getenv("INVOCATION_ID") == "" {
				return errSystemdOnly
			}
		case modeSelf:
			if runtime.GOOS != "darwin" {
				return errSelfOnly
			}

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

		run, notices := runner()

		running := &link.Link{
			Xixo:    config.Xixo,
			Version: version,
			Folders: shared,
			Machine: machine.New(),
			Tokens:  link.Tokens(client, config),
			DPoP:    dpop,
			Log:     slog.New(slog.NewTextHandler(os.Stderr, nil)),
			Work:    workDir(),
			Digests: &digests.Cache{Path: digestsFile(*stateDir)},
			Runner:  run,
			Notices: notices,
			Lend:    config.LendCeiling(),
		}

		ctx, restart := context.WithCancelCause(ctx)
		defer restart(nil)

		running.Identity = update.Identify(version)
		running.Updates = updater(ctx, *updates, *releases, *stateDir, config, running, func() { restart(errRestart) })
		running.Parts = keeper(*updates == modeSystemd, *configPath, *stateDir, config)
		defer running.Parts.Wait()

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
	case "part":
		releases := set.String("releases", "", "the directory that holds each version of the part")
		wanted := set.String("wanted", "", "the file xixo link writes while it wants the part")
		status := set.String("status", "", "the file this command writes the part's state to")

		if len(args) < 2 || strings.HasPrefix(args[1], "-") {
			return errors.New("part takes the name of one part, then its flags")
		}

		if err := parsed(set, append([]string{args[0]}, args[2:]...), stdout); err != nil {
			return err
		}

		recipe, known := parts.Recipes[args[1]]
		if !known {
			return fmt.Errorf("%q is not a part xixo link runs: name any of %s", args[1], strings.Join(parts.Known(), ", "))
		}

		if *releases == "" || *wanted == "" {
			return errors.New("part takes --releases, --wanted, and --state")
		}

		runner := &parts.Runner{
			Recipe: recipe, Releases: *releases, Wanted: *wanted, State: *stateDir, Status: *status,
			Log: slog.New(slog.NewTextHandler(os.Stderr, nil)),
		}

		return runner.Run(ctx)
	case "install":
		xixo := set.String("xixo", "", "the address of xixo")
		issuer := set.String("issuer", "", "the address of the masks issuer xixo link enrolls with")
		user := set.String("user", "", "the account that owns the shared folders, by default this one")
		from := set.String("from", "", "the build of xixo link to install")

		if err := parse(); err != nil {
			return err
		}

		return installed(ctx, installer(*xixo, *issuer, *user, *from, set.Args(), stdout))
	case "start":
		if err := parse(); err != nil {
			return err
		}

		return started(ctx, installer("", "", "", "", nil, stdout))
	case "uninstall":
		if err := parse(); err != nil {
			return err
		}

		return uninstalled(ctx, installer("", "", "", "", nil, stdout))
	case "join":
		if err := parse(); err != nil {
			return err
		}

		return joined(ctx, *configPath, *stateDir, stdin, stdout)
	case "linked":
		if err := parse(); err != nil {
			return err
		}

		return linkedJSON(ctx, *configPath, *stateDir, stdout)
	case "login":
		xixo := set.String("xixo", "", "the address of xixo to sign in to")

		if err := parse(); err != nil {
			return err
		}

		if *xixo == "" {
			return person.ErrNoXixo
		}

		_, err := person.SignIn(ctx, dial.Client(dial.Answered), loginStore(), *xixo, stdout)
		if err != nil {
			return err
		}

		fmt.Fprintf(stdout, "\nSigned in to %s. The sign-in is kept in %s.\n", strings.TrimSuffix(*xixo, "/"), person.DefaultPath())

		return nil
	case "add":
		xixo := set.String("xixo", "", "the address of xixo, when you are signed in to more than one")
		user := set.String("user", "", "the account on the machine that owns the folders, by default the one ssh signs in as")
		off := set.String("off", "", "the lines of the plan to leave off, separated by commas: catalog, extract, or models")

		if err := parse(); err != nil {
			return err
		}

		if set.NArg() == 0 {
			return link.ErrNoHost
		}

		chosen, err := chosenXixo(*xixo)
		if err != nil {
			return err
		}

		token, err := personToken(ctx, chosen)
		if err != nil {
			return err
		}

		return link.Add(ctx, link.Adding{
			Xixo: chosen, Token: token, Host: set.Arg(0), User: *user, Folders: set.Args()[1:],
			Off:      strings.FieldsFunc(*off, func(r rune) bool { return r == ',' || r == ' ' }),
			Terminal: terminal.Is(os.Stdin), SSH: overSSH, Client: dial.Client(dial.Answered), Out: stdout,
		})
	case "remove":
		xixo := set.String("xixo", "", "the address of xixo, when you are signed in to more than one")

		if err := parse(); err != nil {
			return err
		}

		if set.NArg() != 1 {
			return errors.New("remove takes one host, as ssh knows it")
		}

		chosen, err := chosenXixo(*xixo)
		if err != nil {
			return err
		}

		token, err := personToken(ctx, chosen)
		if err != nil {
			return err
		}

		return link.Remove(ctx, link.Unlinking{Xixo: chosen, Token: token, Host: set.Arg(0), SSH: overSSH, Client: dial.Client(dial.Answered), Out: stdout})
	case "readable":
		if len(args) != 2 {
			return errors.New("readable takes one folder")
		}

		return readable(args[1])
	default:
		return fmt.Errorf("%q is not a command. Run xixo-link help to see the commands", args[0])
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

func keeper(systemd bool, configPath, stateDir string, config *state.Config) *parts.Keeper {
	if systemd {
		return &parts.Keeper{
			Dir:     filepath.Join(runtimeDir(updateRequests), "parts"),
			Allowed: config.PartCeiling(),
			Status:  func(name string) string { return filepath.Join("/run/xixo-link-part", name, "status.json") },
		}
	}

	root := filepath.Join(filepath.Dir(configPath), "parts")
	self, _ := os.Executable()

	return &parts.Keeper{
		Dir:     filepath.Join(stateDir, "parts"),
		Allowed: config.PartCeiling(),
		Status:  func(name string) string { return filepath.Join(stateDir, "parts", name+".status.json") },
		Command: func(ctx context.Context, name string) *exec.Cmd {
			command := exec.CommandContext(ctx, self, "part", name,
				"--releases", filepath.Join(root, name, "releases"),
				"--state", filepath.Join(root, name),
				"--wanted", filepath.Join(stateDir, "parts", name),
				"--status", filepath.Join(stateDir, "parts", name+".status.json"))
			command.Stdout = os.Stderr
			command.Stderr = os.Stderr
			command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
			command.WaitDelay = parts.Stopping

			return command
		},
	}
}

func runner() (extract.Runner, []string) {
	if runtime.GOOS != "darwin" {
		return extract.Limited{}, nil
	}

	confine, err := extract.Sandbox()
	if err == nil {
		return extract.Limited{Confine: confine}, nil
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

func cacheDir() string {
	return cacheDirOr(state.DefaultCache)
}

func cacheDirOr(fallback string) string {
	cache, _, _ := strings.Cut(os.Getenv("CACHE_DIRECTORY"), ":")
	if cache == "" {
		cache = fallback
	}

	return cache
}

func digestsFile(stateDir string) string {
	if cache := cacheDir(); cache != "" {
		return filepath.Join(cache, "digests.json")
	}

	return filepath.Join(stateDir, "digests.json")
}

func workDir() string {
	cache := cacheDir()
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

func sentence(said string) string {
	if strings.HasSuffix(said, ".") {
		return said
	}

	return said + "."
}
