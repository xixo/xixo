package watch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"unsafe"

	"golang.org/x/sys/unix"
)

const most = 16384

const watched = unix.IN_CREATE | unix.IN_DELETE | unix.IN_MOVED_FROM | unix.IN_MOVED_TO | unix.IN_CLOSE_WRITE |
	unix.IN_ONLYDIR | unix.IN_DONT_FOLLOW | unix.IN_EXCL_UNLINK

type inotify struct {
	file *os.File
	fd   int
	lock sync.Mutex
	dirs map[int32]string
}

func open() (backend, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}

	return &inotify{file: os.NewFile(uintptr(fd), "inotify"), fd: fd, dirs: map[int32]string{}}, nil
}

func (i *inotify) add(dir string) error {
	wd, err := unix.InotifyAddWatch(i.fd, dir, watched)
	if errors.Is(err, unix.ENOSPC) {
		return errLimit
	}

	if err != nil {
		return err
	}

	i.lock.Lock()
	i.dirs[int32(wd)] = dir
	i.lock.Unlock()

	return nil
}

func (i *inotify) close() error {
	return i.file.Close()
}

func (i *inotify) run(ctx context.Context, events chan<- event, overflow chan<- struct{}) error {
	go func() {
		<-ctx.Done()
		i.file.Close()
	}()

	buffer := make([]byte, 64<<10)

	for {
		read, err := i.file.Read(buffer)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}

			return err
		}

		for offset := 0; offset+unix.SizeofInotifyEvent <= read; {
			raw := (*unix.InotifyEvent)(unsafe.Pointer(&buffer[offset]))
			named := buffer[offset+unix.SizeofInotifyEvent : offset+unix.SizeofInotifyEvent+int(raw.Len)]
			offset += unix.SizeofInotifyEvent + int(raw.Len)

			i.heard(ctx, raw.Wd, raw.Mask, named, events, overflow)
		}
	}
}

func (i *inotify) heard(ctx context.Context, wd int32, mask uint32, named []byte, events chan<- event, overflow chan<- struct{}) {
	if mask&unix.IN_Q_OVERFLOW != 0 {
		select {
		case overflow <- struct{}{}:
		default:
		}

		return
	}

	i.lock.Lock()
	dir, ok := i.dirs[wd]
	if mask&unix.IN_IGNORED != 0 {
		delete(i.dirs, wd)
	}
	i.lock.Unlock()

	if !ok || len(named) == 0 {
		return
	}

	end := 0
	for end < len(named) && named[end] != 0 {
		end++
	}

	seen := event{
		path:    filepath.Join(dir, string(named[:end])),
		dir:     mask&unix.IN_ISDIR != 0,
		created: mask&(unix.IN_CREATE|unix.IN_MOVED_TO) != 0,
	}

	select {
	case events <- seen:
	case <-ctx.Done():
	}
}
