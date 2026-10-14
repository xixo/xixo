//go:build linux

package digests

import (
	"io/fs"
	"strconv"
	"syscall"
)

func stamped(info fs.FileInfo) (Stamp, bool) {
	held, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.Mode().IsRegular() {
		return Stamp{}, false
	}

	return Stamp{
		File:     strconv.FormatUint(uint64(held.Dev), 10) + ":" + strconv.FormatUint(held.Ino, 10),
		Size:     info.Size(),
		Modified: info.ModTime().UnixNano(),
		Changed:  held.Ctim.Nano(),
	}, true
}
