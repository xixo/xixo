//go:build !unix

package folders

import "os"

const (
	noFollow = 0
	nonBlock = 0
)

func blocking(*os.File) error {
	return nil
}
