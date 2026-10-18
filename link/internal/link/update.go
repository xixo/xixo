package link

import (
	"context"

	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/update"
)

type Updater interface {
	Mode() string
	Offer(context.Context, update.Target) error
	Warnings() []string
	Connected() error
}

func (a *Link) greeting(hello machine.Hello) greeting {
	held := greeting{Hello: hello, SHA256: a.Identity.SHA256, MacReader: a.Identity.MacReader}

	if a.Updates != nil {
		held.Updates = a.Updates.Mode()
	}

	return held
}

func (a *Link) connected() {
	if a.Updates == nil {
		return
	}

	if err := a.Updates.Connected(); err != nil {
		a.Log.Warn("xixo link could not note that it connected", "error", err)
	}
}

func (a *Link) updateTo(ctx context.Context, target update.Target) {
	if a.Updates == nil {
		return
	}

	a.work.Add(1)

	go func() {
		defer a.work.Done()

		if err := a.Updates.Offer(ctx, target); err != nil {
			a.Log.Warn("xixo link did not update", "version", target.Version, "error", err)
		}
	}()
}

func (a *Link) updateWarnings() []string {
	if a.Updates == nil {
		return nil
	}

	return a.Updates.Warnings()
}
