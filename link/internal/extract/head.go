package extract

import (
	"io"
	"os"
)

func Head(path string, most int64) ([]byte, error) {
	opened, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	return io.ReadAll(io.LimitReader(opened, most))
}
