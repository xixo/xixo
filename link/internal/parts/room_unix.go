package parts

import (
	"fmt"

	"golang.org/x/sys/unix"
)

func room(dir string, needed int64) error {
	var stat unix.Statfs_t
	if unix.Statfs(dir, &stat) != nil {
		return nil
	}

	free := int64(stat.Bavail) * int64(stat.Bsize)
	if free < needed {
		return fmt.Errorf("%w: %s has %d MB free and the build needs up to %d MB", ErrNoRoom, dir, free>>20, needed>>20)
	}

	return nil
}
