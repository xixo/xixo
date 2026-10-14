package extract

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
	"slices"
	"strconv"
	"syscall"
	"time"
)

const (
	MostMemory  = 4 << 30
	MostFile    = 4 << 30
	MostOutput  = 64 << 20
	DefaultTime = 10 * time.Minute
	measured    = 500 * time.Millisecond
)

var ProgramMemory = map[string]uint64{
	"exiftool": 6 << 30,
}

var (
	ErrStopped = errors.New("the program ran past its deadline and was stopped")
	ErrBudget  = errors.New("the extraction wrote more than its work folder holds, so the program was stopped")
)

const limitScript = `want=$1; files=$2; strict=$3; shift 3; ` +
	`clamp() { hard=$(ulimit -H "-$1"); if [ "$hard" != unlimited ] && [ "$hard" -lt "$2" ]; then echo "$hard"; else echo "$2"; fi; }; ` +
	`ulimit -d "$(clamp d "$want")" 2>/dev/null || [ "$strict" = 0 ] || exit 125; ` +
	`ulimit -f "$(clamp f "$files")" || exit 125; ` +
	`exec "$@"`

type Limited struct {
	Memory  uint64
	File    int64
	Dir     string
	Env     []string
	Watch   string
	Budget  int64
	Confine Confiner
	Refused error
	Inherit *os.File
	Reads   []string
}

func Within(run Runner, dir string, budget int64) Runner {
	held, ok := run.(Limited)
	if !ok {
		return run
	}

	held.Watch = dir
	held.Budget = budget

	if held.Dir == "" {
		held.Dir = dir
	}

	return held
}

func (l Limited) environment() []string {
	held := l.Env
	if held == nil {
		held = os.Environ()
	}

	held = append(slices.Clone(held), "VIPS_BLOCK_UNTRUSTED=1")

	if l.Watch != "" {
		held = append(held, "TMPDIR="+l.Watch)
	}

	if l.Watch != "" && runtime.GOOS == "linux" {
		held = append(held, "HOME="+l.Watch)
	}

	return held
}

func (l Limited) blocks() string {
	most := l.File
	if most <= 0 {
		most = MostFile
	}

	return strconv.FormatInt(max(most/512, 1), 10)
}

func (l Limited) over() bool {
	if l.Watch == "" || l.Budget <= 0 {
		return false
	}

	used := int64(0)

	filepath.WalkDir(l.Watch, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil || !entry.Type().IsRegular() {
			return nil
		}

		if info, err := entry.Info(); err == nil {
			used += info.Size()
		}

		return nil
	})

	return used > l.Budget
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

func strictMemory() string {
	if runtime.GOOS == "linux" {
		return "1"
	}

	return "0"
}

func (l Limited) command(program string, args []string) ([]string, error) {
	if l.Refused != nil {
		return nil, l.Refused
	}

	held := append([]string{"/bin/sh", "-c", limitScript, "xixo-link-limit", strconv.FormatUint(l.memoryFor(program)>>10, 10), l.blocks(), strictMemory(), program}, args...)
	if l.Confine == nil {
		return held, nil
	}

	work := l.Watch
	if work == "" {
		work = l.Dir
	}

	prefix, err := l.Confine(work, program, l.Reads)
	if err != nil {
		return nil, err
	}

	return append(prefix, held...), nil
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

	argv, err := l.command(program, args)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()

	command := exec.Command(argv[0], argv[1:]...)
	command.Dir = l.Dir
	command.Env = l.environment()
	command.Stdout = stdout
	stderr := &capped{most: 16 << 10}
	command.Stderr = stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if l.Inherit != nil {
		inherited, err := inheriting(l.Inherit)
		if err != nil {
			return err
		}

		command.ExtraFiles = inherited
	}

	if err := command.Start(); err != nil {
		return err
	}

	done := make(chan error, 1)
	go func() { done <- command.Wait() }()

	ticker := time.NewTicker(measured)
	defer ticker.Stop()

	for {
		select {
		case err := <-done:
			if err != nil {
				return fmt.Errorf("%s failed: %w: %s", program, err, bytes.TrimSpace(stderr.Bytes()))
			}

			return nil
		case <-ticker.C:
			if l.over() {
				_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
				<-done

				return fmt.Errorf("%s: %w", program, ErrBudget)
			}
		case <-ctx.Done():
			_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
			<-done

			return fmt.Errorf("%s: %w", program, ErrStopped)
		}
	}
}

func inheriting(file *os.File) ([]*os.File, error) {
	fd := int(file.Fd())
	if fd < 3 {
		return nil, ErrNotInPlace
	}

	held := make([]*os.File, fd-2)
	held[fd-3] = file

	return held, nil
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
