//go:build unix && !darwin

package extract

import "golang.org/x/sys/unix"

func setDataLimit(memory uint64) error {
	held := &unix.Rlimit{}
	if err := unix.Getrlimit(unix.RLIMIT_DATA, held); err != nil {
		return err
	}

	if held.Max != unix.RLIM_INFINITY && held.Max < memory {
		memory = held.Max
	}

	if held.Cur != unix.RLIM_INFINITY && held.Cur < memory && held.Cur == held.Max {
		memory = held.Cur
	}

	return unix.Setrlimit(unix.RLIMIT_DATA, &unix.Rlimit{Cur: memory, Max: memory})
}
