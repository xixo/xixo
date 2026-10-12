//go:build !unix

package folders

import "io/fs"

func ownedByUs(fs.FileInfo) bool {
	return true
}
