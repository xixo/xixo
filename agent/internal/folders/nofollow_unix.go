//go:build unix

package folders

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

const (
	noFollow = syscall.O_NOFOLLOW
	nonBlock = syscall.O_NONBLOCK
)

func blocking(opened *os.File) error {
	raw, err := opened.SyscallConn()
	if err != nil {
		return err
	}

	var failed error

	err = raw.Control(func(fd uintptr) {
		flags, err := unix.FcntlInt(fd, unix.F_GETFL, 0)
		if err != nil {
			failed = err

			return
		}

		_, failed = unix.FcntlInt(fd, unix.F_SETFL, flags&^unix.O_NONBLOCK)
	})
	if err != nil {
		return err
	}

	return failed
}
