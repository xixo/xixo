package parts

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	Current   = "current"
	Good      = "good"
	Probation = 2 * time.Minute
	Watching  = 2 * time.Second
	Stopping  = 15 * time.Second
	pulling   = 6 * time.Hour
)

var probation = Probation

var (
	ErrStale     = errors.New("this part was started by an older xixo link, so it starts again with the new one")
	ErrUnhealthy = errors.New("the part did not answer its health check")
	ErrExited    = errors.New("the part stopped on its own")
	errUnwanted  = errors.New("the part is no longer wanted")
)

type Runner struct {
	Recipe   Recipe
	Releases string
	Wanted   string
	State    string
	Status   string
	Client   *http.Client
	Log      *slog.Logger
	Stdout   io.Writer
	Command  func(ctx context.Context, program string, args, env []string) *exec.Cmd
	Env      []string
	Watching time.Duration

	status Status
}

func (r *Runner) Run(ctx context.Context) error {
	if r.Log == nil {
		r.Log = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}

	if r.Client == nil {
		r.Client = &http.Client{Timeout: 10 * time.Second}
	}

	if r.Watching == 0 {
		r.Watching = Watching
	}

	r.status = Status{Name: r.Recipe.Name, Version: r.Recipe.Version, Pulls: []Pull{}}

	wanted, err := ReadWanted(r.Wanted)
	if errors.Is(err, fs.ErrNotExist) {
		return r.stopped()
	}

	if err != nil {
		return r.failed(err)
	}

	if wanted.Version != r.Recipe.Version {
		return r.failed(ErrStale)
	}

	build, err := r.Recipe.Build()
	if err != nil {
		return r.failed(err)
	}

	if err := r.installed(ctx, build); err != nil {
		return r.failed(err)
	}

	version := r.Recipe.Version

	for {
		err := r.serve(ctx, wanted, build, version)

		switch {
		case errors.Is(err, errUnwanted):
			return r.stopped()
		case errors.Is(err, context.Canceled):
			return r.stopped()
		case errors.Is(err, ErrUnhealthy) && version == r.Recipe.Version && r.rolledBack():
			version = pointed(r.Releases, Current)
			r.Log.Warn("the part failed its health check, so the version before it runs", "part", r.Recipe.Name, "version", version)

			continue
		default:
			return r.failed(err)
		}
	}
}

func (r *Runner) installed(ctx context.Context, build Build) error {
	release := filepath.Join(r.Releases, r.Recipe.Version)
	if _, err := os.Stat(filepath.Join(release, build.Command)); err == nil {
		return nil
	}

	r.note(StateFetching, "")

	archive, err := Fetch(ctx, r.Client, build, r.Releases)
	if err != nil {
		return err
	}

	part := release + ".part"
	os.RemoveAll(part)

	if err := Unpack(archive, build.Archive, part); err != nil {
		os.RemoveAll(part)

		return err
	}

	if err := os.Rename(part, release); err != nil {
		return err
	}

	os.Remove(archive)

	return nil
}

func (r *Runner) serve(ctx context.Context, wanted *Wanted, build Build, version string) error {
	if pointed(r.Releases, Current) != version {
		if err := point(r.Releases, Current, version); err != nil {
			return err
		}
	}

	running := pointed(r.Releases, Current)
	program := filepath.Join(r.Releases, running, build.Command)
	r.status.Version = running
	r.note(StateStarting, "")

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	command := r.command(ctx, program, wanted.Settings)
	if err := command.Start(); err != nil {
		return err
	}

	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()

	if err := r.healthy(ctx, wanted.Settings.Port, exited); err != nil {
		if !errors.Is(err, ErrExited) {
			stop(command, exited)
		}

		return err
	}

	if running != pointed(r.Releases, Good) {
		if err := point(r.Releases, Good, running); err != nil {
			r.Log.Warn("could not mark the version good", "error", err)
		}

		prune(r.Releases, running)
	}

	r.status.Port = wanted.Settings.Port
	r.note(StateRunning, "")

	return r.watch(ctx, wanted, exited, command)
}

func (r *Runner) command(ctx context.Context, program string, settings Settings) *exec.Cmd {
	env := append([]string{}, r.Env...)
	env = append(env,
		"HOME="+r.State,
		"OLLAMA_HOST=127.0.0.1:"+strconv.Itoa(settings.Port),
		"OLLAMA_MODELS="+filepath.Join(r.State, "models"),
		"OLLAMA_ORIGINS=http://127.0.0.1,http://localhost",
	)

	if settings.Context > 0 {
		env = append(env, "OLLAMA_CONTEXT_LENGTH="+strconv.Itoa(settings.Context))
	}

	if settings.KeepAlive != "" {
		env = append(env, "OLLAMA_KEEP_ALIVE="+settings.KeepAlive)
	}

	if runtime.GOOS == "linux" {
		env = append(env, "PATH=/usr/bin:/bin")
	} else {
		env = append(env, "PATH="+os.Getenv("PATH"))
	}

	if r.Command != nil {
		return r.Command(ctx, program, r.Recipe.Args, env)
	}

	command := exec.CommandContext(ctx, program, r.Recipe.Args...)
	command.Env = env
	command.Dir = r.State
	command.Stdout = r.out()
	command.Stderr = r.out()
	command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
	command.WaitDelay = Stopping

	return command
}

func (r *Runner) out() io.Writer {
	if r.Stdout != nil {
		return r.Stdout
	}

	return os.Stderr
}

func (r *Runner) healthy(ctx context.Context, port int, exited <-chan error) error {
	deadline := time.Now().Add(probation)
	address := "http://127.0.0.1:" + strconv.Itoa(port) + r.Recipe.Health

	for {
		select {
		case err := <-exited:
			return fmt.Errorf("%w: %w: %v", ErrUnhealthy, ErrExited, err)
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if r.answers(ctx, address) {
			return nil
		}

		if time.Now().After(deadline) {
			return ErrUnhealthy
		}

		time.Sleep(time.Second)
	}
}

func (r *Runner) answers(ctx context.Context, address string) bool {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return false
	}

	response, err := r.Client.Do(request)
	if err != nil {
		return false
	}

	io.Copy(io.Discard, response.Body)
	response.Body.Close()

	return response.StatusCode == http.StatusOK
}

func (r *Runner) watch(ctx context.Context, wanted *Wanted, exited <-chan error, command *exec.Cmd) error {
	pulled := map[string]bool{}
	ticker := time.NewTicker(r.Watching)
	defer ticker.Stop()

	for {
		for _, model := range wanted.Settings.Models {
			if pulled[model] {
				continue
			}

			pulled[model] = true

			if err := r.pull(ctx, wanted.Settings.Port, model); err != nil {
				r.Log.Warn("a model could not be pulled", "model", model, "error", err)
			}
		}

		select {
		case err := <-exited:
			return fmt.Errorf("%w: %v", ErrExited, err)
		case <-ctx.Done():
			stop(command, exited)

			return ctx.Err()
		case <-ticker.C:
		}

		again, err := ReadWanted(r.Wanted)
		if errors.Is(err, fs.ErrNotExist) {
			stop(command, exited)

			return errUnwanted
		}

		if err == nil {
			wanted = again
		}
	}
}

func (r *Runner) pull(ctx context.Context, port int, model string) error {
	ctx, cancel := context.WithTimeout(ctx, pulling)
	defer cancel()

	index := len(r.status.Pulls)
	r.status.Pulls = append(r.status.Pulls, Pull{Model: model})
	r.note(StateRunning, "")

	body, _ := json.Marshal(map[string]any{"name": model, "stream": true})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://127.0.0.1:"+strconv.Itoa(port)+"/api/pull", strings.NewReader(string(body)))
	if err != nil {
		return err
	}

	request.Header.Set("Content-Type", "application/json")

	response, err := (&http.Client{}).Do(request)
	if err != nil {
		r.status.Pulls[index].Error = err.Error()
		r.note(StateRunning, "")

		return err
	}
	defer response.Body.Close()

	lines := bufio.NewScanner(response.Body)
	lines.Buffer(make([]byte, 1<<20), 1<<20)
	last := time.Now()

	for lines.Scan() {
		told := struct {
			Status    string `json:"status"`
			Total     int64  `json:"total"`
			Completed int64  `json:"completed"`
			Error     string `json:"error"`
		}{}
		if json.Unmarshal(lines.Bytes(), &told) != nil {
			continue
		}

		if told.Error != "" {
			r.status.Pulls[index].Error = told.Error
			r.note(StateRunning, "")

			return errors.New(told.Error)
		}

		if told.Total > 0 {
			r.status.Pulls[index].Done = told.Completed
			r.status.Pulls[index].Total = told.Total
		}

		if told.Status == "success" {
			r.status.Pulls[index].Ready = true
		}

		if time.Since(last) > time.Second || told.Status == "success" {
			r.note(StateRunning, "")
			last = time.Now()
		}
	}

	if response.StatusCode != http.StatusOK {
		r.status.Pulls[index].Error = response.Status
		r.note(StateRunning, "")

		return errors.New(response.Status)
	}

	r.status.Pulls[index].Ready = true
	r.note(StateRunning, "")

	return nil
}

func (r *Runner) rolledBack() bool {
	good := pointed(r.Releases, Good)
	if good == "" || good == pointed(r.Releases, Current) {
		return false
	}

	return point(r.Releases, Current, good) == nil
}

func (r *Runner) note(state, warning string) {
	r.status.State = state
	r.status.Warning = warning

	if r.Status == "" {
		return
	}

	if err := WriteStatus(r.Status, r.status); err != nil {
		r.Log.Warn("could not write the part's status", "error", err)
	}
}

func (r *Runner) failed(err error) error {
	r.note(StateFailed, err.Error())

	return err
}

func (r *Runner) stopped() error {
	r.note(StateStopped, "")

	return nil
}

func stop(command *exec.Cmd, exited <-chan error) {
	if command.Process == nil {
		return
	}

	command.Process.Signal(os.Interrupt)

	select {
	case <-exited:
	case <-time.After(Stopping):
		command.Process.Kill()
		<-exited
	}
}
