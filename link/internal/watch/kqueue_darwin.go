package watch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

const most = 4096

type stamp struct {
	size int64
	at   time.Time
	dir  bool
}

type kqueue struct {
	kq    int
	lock  sync.Mutex
	dirs  map[int]string
	fds   map[string]int
	seen  map[string]map[string]stamp
	shut  bool
	ended chan struct{}
}

func open() (backend, error) {
	kq, err := unix.Kqueue()
	if err != nil {
		return nil, err
	}

	unix.CloseOnExec(kq)

	return &kqueue{kq: kq, dirs: map[int]string{}, fds: map[string]int{}, seen: map[string]map[string]stamp{}, ended: make(chan struct{})}, nil
}

func (k *kqueue) add(dir string) error {
	k.lock.Lock()
	_, held := k.fds[dir]
	k.lock.Unlock()

	if held {
		return nil
	}

	fd, err := unix.Open(dir, unix.O_EVTONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if errors.Is(err, unix.EMFILE) || errors.Is(err, unix.ENFILE) {
		return errLimit
	}

	if err != nil {
		return err
	}

	change := unix.Kevent_t{}
	unix.SetKevent(&change, fd, unix.EVFILT_VNODE, unix.EV_ADD|unix.EV_CLEAR|unix.EV_ENABLE)
	change.Fflags = unix.NOTE_WRITE | unix.NOTE_DELETE | unix.NOTE_RENAME

	if _, err := unix.Kevent(k.kq, []unix.Kevent_t{change}, nil, nil); err != nil {
		unix.Close(fd)

		return err
	}

	listed := entries(dir)

	k.lock.Lock()
	k.dirs[fd] = dir
	k.fds[dir] = fd
	k.seen[dir] = listed
	k.lock.Unlock()

	return nil
}

func entries(dir string) map[string]stamp {
	held := map[string]stamp{}

	listed, err := os.ReadDir(dir)
	if err != nil {
		return held
	}

	for _, entry := range listed {
		if entry.Type()&os.ModeSymlink != 0 {
			continue
		}

		if entry.IsDir() {
			held[entry.Name()] = stamp{dir: true}

			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		held[entry.Name()] = stamp{size: info.Size(), at: info.ModTime()}
	}

	return held
}

func (k *kqueue) forget(fd int) {
	k.lock.Lock()
	defer k.lock.Unlock()

	dir, ok := k.dirs[fd]
	if !ok {
		return
	}

	delete(k.dirs, fd)
	delete(k.fds, dir)
	delete(k.seen, dir)
	unix.Close(fd)
}

func (k *kqueue) close() error {
	k.lock.Lock()
	if k.shut {
		k.lock.Unlock()

		return nil
	}

	k.shut = true
	k.lock.Unlock()

	<-k.ended

	k.lock.Lock()
	defer k.lock.Unlock()

	for fd := range k.dirs {
		unix.Close(fd)
	}

	return unix.Close(k.kq)
}

func (k *kqueue) run(ctx context.Context, events chan<- event, _ chan<- struct{}) error {
	defer close(k.ended)

	heard := make([]unix.Kevent_t, 64)
	wait := unix.NsecToTimespec(int64(250 * time.Millisecond))

	for {
		k.lock.Lock()
		shut := k.shut
		k.lock.Unlock()

		if shut || ctx.Err() != nil {
			return nil
		}

		count, err := unix.Kevent(k.kq, nil, heard, &wait)
		if errors.Is(err, unix.EINTR) {
			continue
		}

		if err != nil {
			return err
		}

		for _, raw := range heard[:count] {
			fd := int(raw.Ident)

			if raw.Fflags&(unix.NOTE_DELETE|unix.NOTE_RENAME) != 0 {
				k.forget(fd)

				continue
			}

			if raw.Fflags&unix.NOTE_WRITE != 0 {
				k.changed(ctx, fd, events)
			}
		}
	}
}

func (k *kqueue) changed(ctx context.Context, fd int, events chan<- event) {
	k.lock.Lock()
	dir, ok := k.dirs[fd]
	before := k.seen[dir]
	k.lock.Unlock()

	if !ok {
		return
	}

	after := entries(dir)

	k.lock.Lock()
	k.seen[dir] = after
	k.lock.Unlock()

	for name, now := range after {
		was, existed := before[name]
		if existed && was.size == now.size && was.at.Equal(now.at) && was.dir == now.dir {
			continue
		}

		k.send(ctx, events, event{path: filepath.Join(dir, name), dir: now.dir, created: !existed || was.dir != now.dir})
	}

	for name, was := range before {
		if _, kept := after[name]; !kept {
			k.send(ctx, events, event{path: filepath.Join(dir, name), dir: was.dir})
		}
	}
}

func (k *kqueue) send(ctx context.Context, events chan<- event, seen event) {
	select {
	case events <- seen:
	case <-ctx.Done():
	}
}
