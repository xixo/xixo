package link

import (
	"context"
	"errors"

	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/watch"
)

const mostUntold = 64

func (a *Link) watch(ctx context.Context) {
	roots := map[string]string{}

	for _, folder := range a.Folders.Names() {
		if real, err := a.Folders.Real(folder); err == nil {
			roots[folder] = real
		}
	}

	if len(roots) == 0 {
		return
	}

	a.watching = &watch.Watcher{Roots: roots, Skip: folders.Skips, Log: a.Log}
	untold := make(chan watch.Change, mostUntold)

	a.work.Go(func() {
		for change := range untold {
			if err := a.wire.perform(ctx, "changed", change); err != nil && ctx.Err() == nil {
				a.Log.Info("a change was not told; the next walk finds it", "folder", change.Folder, "error", err)
			}
		}
	})

	a.work.Go(func() {
		defer close(untold)

		err := a.watching.Run(ctx, func(change watch.Change) {
			select {
			case untold <- change:
			default:
				a.Log.Info("too many changes wait to be told; the next walk finds them", "folder", change.Folder)
			}
		})

		if err != nil && ctx.Err() == nil && !errors.Is(err, context.Canceled) {
			a.Log.Warn("watching the shared folders stopped", "error", err)
		}
	})
}
