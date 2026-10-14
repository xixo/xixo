package extract

import (
	"os"
	"strconv"
)

func reach(file *os.File) (string, *os.File, error) {
	return "/proc/self/fd/" + strconv.FormatUint(uint64(file.Fd()), 10), file, nil
}
