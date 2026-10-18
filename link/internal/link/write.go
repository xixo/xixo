package link

import (
	"context"
	"io"
	"time"

	"github.com/xixo/xixo/link/internal/folders"
)

const (
	verbWrite   = "write"
	verbRemove  = "remove"
	MostWritten = 1 << 40
)

type Writing struct {
	Folder     string     `json:"folder"`
	Path       string     `json:"path"`
	Upload     string     `json:"upload"`
	Size       int64      `json:"size"`
	Replace    bool       `json:"replace"`
	ModifiedAt *time.Time `json:"modified_at,omitempty"`
	Relayed    bool       `json:"relayed,omitempty"`
}

type Removing struct {
	Folder string `json:"folder"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Prune  bool   `json:"prune,omitempty"`
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

	if wanted.Size < 0 || wanted.Size > MostWritten {
		return nil, ErrTooLarge
	}

	cancel := context.CancelFunc(func() {})
	if !wanted.Relayed {
		ctx, cancel = context.WithTimeout(ctx, fetchedWithin(wanted.Size))
	}
	defer cancel()

	body, err := a.body(ctx, wanted)
	if err != nil {
		return nil, err
	}
	defer body.Close()

	modified := time.Time{}
	if wanted.ModifiedAt != nil {
		modified = *wanted.ModifiedAt
	}

	return a.Folders.WriteModified(ctx, wanted.Folder, wanted.Path, body, wanted.Size, wanted.Replace, modified)
}

func (a *Link) body(ctx context.Context, wanted Writing) (io.ReadCloser, error) {
	if !wanted.Relayed {
		response, err := a.upload(ctx, wanted.Upload, wanted.Size)
		if err != nil {
			return nil, err
		}

		return response.Body, nil
	}

	if !uploadName.MatchString(wanted.Upload) {
		return nil, ErrNoUpload
	}

	reader, writer := io.Pipe()

	go func() {
		writer.CloseWithError(a.relayed(ctx, wanted.Upload, wanted.Size, writer))
	}()

	return reader, nil
}

func (a *Link) remove(ctx context.Context, asked *Request) {
	wanted := Removing{}
	if err := strictly(asked.Args, &wanted); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	removed, err := a.Folders.Remove(ctx, wanted.Folder, wanted.Path, wanted.SHA256, wanted.Size, wanted.Prune)
	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	a.reply(ctx, asked.Request, removed)
}
