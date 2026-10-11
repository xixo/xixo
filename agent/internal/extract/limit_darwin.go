package extract

import (
	"errors"

	"golang.org/x/sys/unix"
)

func setDataLimit(memory uint64) error {
	err := unix.Setrlimit(unix.RLIMIT_DATA, &unix.Rlimit{Cur: memory, Max: memory})
	if errors.Is(err, unix.EINVAL) {
		return nil
	}

	return err
}
