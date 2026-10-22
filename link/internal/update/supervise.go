package update

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

const (
	Probation = 3 * time.Minute
	stopping  = 10 * time.Second
)

type Supervisor struct {
	Self      string
	Releases  string
	State     string
	Args      []string
	Probation time.Duration
	Poll      time.Duration
	Pause     time.Duration
	Log       *slog.Logger
}

func (s *Supervisor) settle() {
	if s.Probation == 0 {
		s.Probation = Probation
	}

	if s.Poll == 0 {
		s.Poll = 2 * time.Second
	}

	if s.Pause == 0 {
		s.Pause = time.Second
	}

	if s.Log == nil {
		s.Log = slog.New(slog.DiscardHandler)
	}
}

func (s *Supervisor) Run(ctx context.Context) int {
	s.settle()

	for {
		release := Pointed(s.Releases, Current)
		good := Pointed(s.Releases, Good)
		path := s.Self

		if release != "" {
			path = filepath.Join(s.Releases, release, Binary)
		}

		trial := release != good
		status, connected, err := s.child(ctx, path, release, trial)

		switch {
		case ctx.Err() != nil:
			return 0
		case trial && !connected:
			s.Log.Warn("the new xixo link did not connect, so xixo link goes back to the one before it", "release", release, "error", err)
			s.rollback(release, good, err)
		}

		if trial && !connected {
			continue
		}

		if status != Restart {
			return status
		}

		select {
		case <-ctx.Done():
			return 0
		case <-time.After(s.Pause):
		}
	}
}

func (s *Supervisor) rollback(release, good string, cause error) {
	if good == "" {
		Unpoint(s.Releases, Current)
	} else {
		Point(s.Releases, Current, good)
	}

	why := "it did not connect to xixo in time"
	if cause != nil {
		why = cause.Error()
	}

	Write(filepath.Join(s.State, ResultFile), Result{SHA256: s.sha(release), Error: why, At: time.Now().UTC()}, 0o600)
}

func (s *Supervisor) sha(release string) string {
	if release == "" {
		return ""
	}

	held, _ := Digest(filepath.Join(s.Releases, release, Binary))

	return held
}

func (s *Supervisor) promote(release string) {
	if release == "" {
		return
	}

	if err := Point(s.Releases, Good, release); err != nil {
		s.Log.Warn("xixo link could not keep the release that connected as the good one", "release", release, "error", err)
	}

	serial, err := Floor(filepath.Join(s.Releases, release, FloorFile))
	if err == nil && serial > 0 {
		err = Raise(FloorFor(s.Releases), serial)
	}

	if err != nil {
		s.Log.Warn("xixo link could not keep the serial of the release that connected", "release", release, "error", err)
	}
}

func (s *Supervisor) child(ctx context.Context, path, release string, trial bool) (int, bool, error) {
	args := append([]string{"run"}, s.Args...)
	args = append(args, "--supervised", "--releases", s.Releases)

	command := exec.Command(path, args...)
	command.Stdin = nil
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	started := time.Now()

	if err := command.Start(); err != nil {
		return 1, false, fmt.Errorf("it did not start: %w", err)
	}

	done := make(chan error, 1)
	go func() { done <- command.Wait() }()

	var deadline <-chan time.Time
	var poll *time.Ticker
	var polled <-chan time.Time

	if trial {
		timer := time.NewTimer(s.Probation)
		defer timer.Stop()
		deadline = timer.C
		poll = time.NewTicker(s.Poll)
		defer poll.Stop()
		polled = poll.C
	}

	connected := !trial

	for {
		select {
		case err := <-done:
			if trial && !connected && s.heard(command.Process.Pid, started) {
				connected = true
				s.promote(release)
			}

			return exited(err), connected, describe(err)
		case <-ctx.Done():
			stop(command, done)

			return 0, connected, ctx.Err()
		case <-polled:
			if s.heard(command.Process.Pid, started) {
				connected = true
				s.promote(release)
				poll.Stop()
				polled = nil
				deadline = nil
			}
		case <-deadline:
			stop(command, done)

			return 1, false, errors.New("it did not connect to xixo in time")
		}
	}
}

func (s *Supervisor) heard(pid int, since time.Time) bool {
	held := Running{}
	if Read(filepath.Join(s.State, RunningFile), &held) != nil {
		return false
	}

	return held.PID == pid && !held.At.Before(since.Add(-time.Second))
}

func stop(command *exec.Cmd, done chan error) {
	command.Process.Signal(syscall.SIGTERM)

	select {
	case <-done:
	case <-time.After(stopping):
		command.Process.Kill()
		<-done
	}
}

func exited(err error) int {
	if err == nil {
		return 0
	}

	held := &exec.ExitError{}
	if errors.As(err, &held) {
		if code := held.ExitCode(); code >= 0 {
			return code
		}
	}

	return 1
}

func describe(err error) error {
	if err == nil {
		return errors.New("it stopped before it connected to xixo")
	}

	return fmt.Errorf("it stopped before it connected to xixo: %w", err)
}
