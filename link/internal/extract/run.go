package extract

import (
	"context"
	"fmt"
)

func Run(ctx context.Context, in Input) (*Output, error) {
	chosen := For(in.MIME, in.Name)
	if chosen == nil {
		return nil, ErrUnhandled
	}

	if !usable(chosen) {
		return nil, fmt.Errorf("this machine lacks a program the %s extractor needs", chosen.Name())
	}

	out, err := chosen.Extract(ctx, in)
	if err != nil {
		return nil, err
	}

	if out == nil {
		out = &Output{}
	}

	out.Extractor = chosen.Name()

	if err := Common(ctx, in, out); err != nil {
		return nil, err
	}

	return out, nil
}
