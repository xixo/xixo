//go:build linux

package folders

import "golang.org/x/sys/unix"

func (o *Opened) Forget() {
	unix.Fadvise(int(o.file.Fd()), 0, 0, unix.FADV_DONTNEED)
}
