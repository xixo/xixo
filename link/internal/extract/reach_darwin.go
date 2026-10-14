package extract

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"unsafe"

	"golang.org/x/sys/unix"
)

func reach(file *os.File) (string, *os.File, error) {
	raw, err := file.SyscallConn()
	if err != nil {
		return "", nil, err
	}

	held := make([]byte, unix.PathMax)
	var failed error

	err = raw.Control(func(fd uintptr) {
		_, failed = unix.FcntlInt(fd, unix.F_GETPATH, int(uintptr(unsafe.Pointer(&held[0]))))
	})
	runtime.KeepAlive(held)

	if err != nil {
		return "", nil, err
	}

	if failed != nil {
		return "", nil, failed
	}

	path, _, _ := bytes.Cut(held, []byte{0})
	if len(path) == 0 || !filepath.IsAbs(string(path)) {
		return "", nil, ErrNotInPlace
	}

	return string(path), nil, nil
}
