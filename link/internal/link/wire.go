package link

import (
	"context"
	"errors"
	"sync"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/cable"
)

var ErrApart = errors.New("this machine is not connected to xixo")

const (
	rejoin  = time.Minute
	written = 30 * time.Second
	kept    = 4096
)

type wire struct {
	lock  sync.RWMutex
	once  sync.Once
	conn  *cable.Conn
	token *masks.Token
	up    chan struct{}
}

func (l *wire) ready() {
	l.once.Do(func() { l.up = make(chan struct{}) })
}

func (l *wire) swap(conn *cable.Conn, token *masks.Token) {
	l.ready()
	l.lock.Lock()
	defer l.lock.Unlock()

	old := l.conn
	l.conn, l.token = conn, token

	switch {
	case conn != nil && old == nil:
		close(l.up)
	case conn == nil && old != nil:
		l.up = make(chan struct{})
	}
}

func (l *wire) held(ctx context.Context) (*cable.Conn, *masks.Token, func(), error) {
	l.ready()
	timer := time.NewTimer(rejoin)
	defer timer.Stop()

	for {
		l.lock.RLock()
		if l.conn != nil {
			return l.conn, l.token, l.lock.RUnlock, nil
		}

		up := l.up
		l.lock.RUnlock()

		select {
		case <-up:
		case <-ctx.Done():
			return nil, nil, nil, ctx.Err()
		case <-timer.C:
			return nil, nil, nil, ErrApart
		}
	}
}

func (l *wire) current(ctx context.Context) (*cable.Conn, *masks.Token, error) {
	conn, token, release, err := l.held(ctx)
	if err != nil {
		return nil, nil, err
	}

	release()

	return conn, token, nil
}

func (l *wire) perform(ctx context.Context, action string, payload any) error {
	conn, _, release, err := l.held(ctx)
	if err != nil {
		return err
	}
	defer release()

	ctx, cancel := context.WithTimeout(ctx, written)
	defer cancel()

	return conn.Perform(ctx, action, payload)
}

type recent struct {
	lock  sync.Mutex
	seen  map[string]bool
	order []string
}

func (r *recent) fresh(request string) bool {
	r.lock.Lock()
	defer r.lock.Unlock()

	if r.seen == nil {
		r.seen = map[string]bool{}
	}

	if r.seen[request] {
		return false
	}

	r.seen[request] = true
	r.order = append(r.order, request)

	if len(r.order) > kept {
		delete(r.seen, r.order[0])
		r.order = r.order[1:]
	}

	return true
}
