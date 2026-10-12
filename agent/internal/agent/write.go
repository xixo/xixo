package agent

import (
	"context"
	"os"
	"path/filepath"

	"github.com/xixo/xixo/agent/internal/folders"
)

const verbWrite = "write"

type Writing struct {
	Folder  string `json:"folder"`
	Path    string `json:"path"`
	Upload  string `json:"upload"`
	Size    int64  `json:"size"`
	Replace bool   `json:"replace"`
}

func (s *session) write(ctx context.Context, asked *Request) {
	wanted := Writing{}
	if err := decode(asked.Args, &wanted); err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	written, err := s.written(ctx, wanted)
	if err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	s.reply(ctx, asked.Request, written)
}

func (s *session) written(ctx context.Context, wanted Writing) (any, error) {
	if !s.Folders.Shares(wanted.Folder) {
		return nil, folders.ErrUnshared
	}

	if !s.Folders.Writes(wanted.Folder) {
		return nil, folders.ErrReadOnly
	}

	work, err := os.MkdirTemp(s.Work, "write-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)

	fetched, _, err := s.fetch(ctx, Extraction{
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

	return s.Folders.Write(wanted.Folder, wanted.Path, opened, wanted.Size, wanted.Replace)
}
