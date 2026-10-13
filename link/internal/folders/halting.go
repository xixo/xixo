package folders

import (
	"context"
	"io"
)

type halting struct {
	ctx  context.Context
	from io.Reader
}

func Halting(ctx context.Context, from io.Reader) io.Reader {
	return &halting{ctx: ctx, from: from}
}

func (h *halting) Read(p []byte) (int, error) {
	if err := h.ctx.Err(); err != nil {
		return 0, err
	}

	return h.from.Read(p)
}
