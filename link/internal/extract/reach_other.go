//go:build !linux && !darwin

package extract

import "os"

func reach(*os.File) (string, *os.File, error) {
	return "", nil, ErrNotInPlace
}
