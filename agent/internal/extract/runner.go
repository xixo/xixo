package extract

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"time"
)

const (
	MostMemory  = 4 << 30
	MostOutput  = 64 << 20
	LimitedArg  = "__limited"
	DefaultTime = 10 * time.Minute
)

var ErrStopped = errors.New("the program ran past its deadline and was stopped")

type Limited struct {
	Memory uint64
	Dir    string
	Env    []string
}

func init() {
	if len(os.Args) > 3 && os.Args[1] == LimitedArg {
		os.Exit(limitedExec(os.Args[2], os.Args[3:]))
	}
}

func limitedExec(memory string, args []string) int {
	held, err := strconv.ParseUint(memory, 10, 64)
	if err != nil || len(args) == 0 {
		fmt.Fprintln(os.Stderr, "xixo-agent: a limited run needs a memory cap and a program")

		return 2
	}

	if err := setDataLimit(held); err != nil {
		fmt.Fprintln(os.Stderr, "xixo-agent: the memory cap could not be set:", err)

		return 2
	}

	program, err := exec.LookPath(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "xixo-agent:", err)

		return 127
	}

	err = syscall.Exec(program, args, os.Environ())
	fmt.Fprintln(os.Stderr, "xixo-agent:", err)

	return 126
}

func (l Limited) Run(ctx context.Context, limit time.Duration, program string, args ...string) ([]byte, error) {
	out := &capped{most: MostOutput}
	err := l.RunTo(ctx, limit, out, program, args...)

	return out.Bytes(), err
}

func (l Limited) RunTo(ctx context.Context, limit time.Duration, stdout io.Writer, program string, args ...string) error {
	if limit <= 0 {
		limit = DefaultTime
	}

	memory := l.Memory
	if memory == 0 {
		memory = MostMemory
	}

	self, err := os.Executable()
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()

	command := exec.Command(self, append([]string{LimitedArg, strconv.FormatUint(memory, 10), program}, args...)...)
	command.Dir = l.Dir
	command.Env = l.Env
	command.Stdout = stdout
	stderr := &capped{most: 16 << 10}
	command.Stderr = stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if err := command.Start(); err != nil {
		return err
	}

	done := make(chan error, 1)
	go func() { done <- command.Wait() }()

	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("%s failed: %w: %s", program, err, bytes.TrimSpace(stderr.Bytes()))
		}

		return nil
	case <-ctx.Done():
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		<-done

		return fmt.Errorf("%s: %w", program, ErrStopped)
	}
}

type capped struct {
	bytes.Buffer
	most int
}

func (c *capped) Write(p []byte) (int, error) {
	room := c.most - c.Len()
	if room > 0 {
		c.Buffer.Write(p[:min(room, len(p))])
	}

	return len(p), nil
}
