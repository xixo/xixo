//go:build !unix

package folders

import "io/fs"

func identity(fs.FileInfo) string {
	return ""
}
