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
	using sync.RWMutex
	lock  sync.Mutex
	conn  *cable.Conn
	token *masks.Token
	up    chan struct{}
}

func (l *wire) swap(conn *cable.Conn, token *masks.Token) *cable.Conn {
	l.using.Lock()
	defer l.using.Unlock()

	l.lock.Lock()
	defer l.lock.Unlock()

	if l.up == nil {
		l.up = make(chan struct{})
	}

	old := l.conn
	l.conn, l.token = conn, token

	switch {
	case conn != nil && old == nil:
		close(l.up)
	case conn == nil && old != nil:
		l.up = make(chan struct{})
	}

	return old
}

func (l *wire) current(ctx context.Context) (*cable.Conn, *masks.Token, error) {
	timer := time.NewTimer(rejoin)
	defer timer.Stop()

	for {
		l.lock.Lock()
		if l.up == nil {
			l.up = make(chan struct{})
		}

		conn, token, up := l.conn, l.token, l.up
		l.lock.Unlock()

		if conn != nil {
			return conn, token, nil
		}

		select {
		case <-up:
		case <-ctx.Done():
			return nil, nil, ctx.Err()
		case <-timer.C:
			return nil, nil, ErrApart
		}
	}
}

func (l *wire) perform(ctx context.Context, action string, payload any) error {
	if _, _, err := l.current(ctx); err != nil {
		return err
	}

	l.using.RLock()
	defer l.using.RUnlock()

	l.lock.Lock()
	conn := l.conn
	l.lock.Unlock()

	if conn == nil {
		return ErrApart
	}

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
