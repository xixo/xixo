package link

import (
	"context"
	"os"
	"path/filepath"

	"github.com/xixo/xixo/link/internal/folders"
)

const verbWrite = "write"

type Writing struct {
	Folder  string `json:"folder"`
	Path    string `json:"path"`
	Upload  string `json:"upload"`
	Size    int64  `json:"size"`
	Replace bool   `json:"replace"`
}

func (a *Link) write(ctx context.Context, asked *Request) {
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

	return a.Folders.Write(wanted.Folder, wanted.Path, opened, wanted.Size, wanted.Replace)
}
