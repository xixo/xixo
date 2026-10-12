//go:build unix

package folders

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestOpeningAFIFOReturnsAtOnce(t *testing.T) {
	shared := t.TempDir()

	if err := syscall.Mkfifo(filepath.Join(shared, "pipe"), 0o644); err != nil {
		t.Skipf("no fifo: %v", err)
	}

	done := make(chan error, 1)

	go func() {
		_, err := New(ReadOnly(shared)).Open(shared, "pipe")
		done <- err
	}()

	select {
	case err := <-done:
		if !errors.Is(err, ErrNotFile) {
			t.Fatalf("a fifo opened with %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("opening a fifo hung")
	}
}

func TestAnOpenedFileReadsBlocking(t *testing.T) {
	shared := t.TempDir()
	os.WriteFile(filepath.Join(shared, "a.txt"), []byte("abc"), 0o644)

	opened, err := New(ReadOnly(shared)).Open(shared, "a.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()

	file := opened.ReadCloser.(*os.File)
	raw, _ := file.SyscallConn()

	raw.Control(func(fd uintptr) {
		flags, _, _ := syscall.Syscall(syscall.SYS_FCNTL, fd, syscall.F_GETFL, 0)
		if flags&syscall.O_NONBLOCK != 0 {
			t.Error("the file is still non-blocking")
		}
	})
}
