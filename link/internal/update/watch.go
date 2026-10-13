package update

import (
	"context"
	"os"
	"time"
)

func Replaced(ctx context.Context, path string, every time.Duration) bool {
	first, err := os.Stat(path)
	if err != nil {
		return false
	}

	ticker := time.NewTicker(every)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return false
		case <-ticker.C:
		}

		held, err := os.Stat(path)
		if err != nil {
			continue
		}

		if !os.SameFile(first, held) || held.Size() != first.Size() || !held.ModTime().Equal(first.ModTime()) {
			return true
		}
	}
}
