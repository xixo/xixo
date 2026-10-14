//go:build !linux && !darwin

package digests

import "io/fs"

func stamped(fs.FileInfo) (Stamp, bool) {
	return Stamp{}, false
}
