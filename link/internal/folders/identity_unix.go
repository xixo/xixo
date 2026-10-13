//go:build unix

package folders

import (
	"io/fs"
	"strconv"
	"syscall"
)

func identity(info fs.FileInfo) string {
	held, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}

	return strconv.FormatUint(uint64(held.Dev), 10) + ":" + strconv.FormatUint(uint64(held.Ino), 10)
}
