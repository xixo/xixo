package extract

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"
)

const (
	MostMemory  = 4 << 30
	MostOutput  = 64 << 20
	DefaultTime = 10 * time.Minute
)

var ProgramMemory = map[string]uint64{
	"exiftool": 6 << 30,
}

var ErrStopped = errors.New("the program ran past its deadline and was stopped")

const cappedScript = `want=$1; shift; hard=$(ulimit -H -d); if [ "$hard" != unlimited ] && [ "$hard" -lt "$want" ]; then want=$hard; fi; ulimit -d "$want" || exit 125; exec "$@"`

const uncappedScript = `shift; exec "$@"`

type Limited struct {
	Memory uint64
	Dir    string
	Env    []string
}

func (l Limited) memoryFor(program string) uint64 {
	if l.Memory != 0 {
		return l.Memory
	}

	if held, ok := ProgramMemory[filepath.Base(program)]; ok {
		return held
	}

	return MostMemory
}

func limitScript() string {
	if runtime.GOOS == "darwin" {
		return uncappedScript
	}

	return cappedScript
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

	kilobytes := strconv.FormatUint(l.memoryFor(program)>>10, 10)

	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()

	command := exec.Command("/bin/sh", append([]string{"-c", limitScript(), "xixo-agent-limit", kilobytes, program}, args...)...)
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
