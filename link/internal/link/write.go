package link

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/state"
)

const (
	verbWrite  = "write"
	verbRemove = "remove"
)

type Writing struct {
	Folder     string     `json:"folder"`
	Path       string     `json:"path"`
	Upload     string     `json:"upload"`
	Size       int64      `json:"size"`
	Replace    bool       `json:"replace"`
	ModifiedAt *time.Time `json:"modified_at,omitempty"`
}

type Removing struct {
	Folder string `json:"folder"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Prune  bool   `json:"prune,omitempty"`
}

func (a *Link) write(ctx context.Context, asked *Request) {
	if err := a.unoffered(toolFor[verbPlace]); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	wanted := Writing{}
	if err := decode(asked.Args, &wanted); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	written, err := a.written(ctx, wanted)
	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	a.reply(ctx, asked.Request, written)
}

func (a *Link) written(ctx context.Context, wanted Writing) (any, error) {
	if !a.Folders.Shares(wanted.Folder) {
		return nil, folders.ErrUnshared
	}

	if !a.Folders.Writes(wanted.Folder) {
		return nil, folders.ErrReadOnly
	}

	work, err := os.MkdirTemp(a.Work, "write-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)

	fetched, _, err := a.fetch(ctx, Extraction{
		Source:   Source{Upload: wanted.Upload},
		Filename: filepath.Base(wanted.Path),
		Size:     wanted.Size,
	}, work)
	if err != nil {
		return nil, err
	}

	opened, err := os.Open(fetched)
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	modified := time.Time{}
	if wanted.ModifiedAt != nil {
		modified = *wanted.ModifiedAt
	}

	return a.Folders.WriteModified(wanted.Folder, wanted.Path, opened, wanted.Size, wanted.Replace, modified)
}

func (a *Link) remove(ctx context.Context, asked *Request) {
	if err := a.unoffered(state.ToolWrite); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	wanted := Removing{}
	if err := strictly(asked.Args, &wanted); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	removed, err := a.Folders.Remove(wanted.Folder, wanted.Path, wanted.SHA256, wanted.Size, wanted.Prune)
	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	a.reply(ctx, asked.Request, removed)
}
