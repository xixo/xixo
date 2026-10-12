//go:build unix

package folders

import (
	"io/fs"
	"os"
	"syscall"
)

func ownedByUs(info fs.FileInfo) bool {
	held, ok := info.Sys().(*syscall.Stat_t)

	return ok && (held.Uid == 0 || int(held.Uid) == os.Getuid())
}
