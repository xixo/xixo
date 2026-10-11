package plain

import (
	"context"
	"strings"

	"github.com/xixo/xixo/agent/internal/extract"
)

type Text struct{}

func (Text) Name() string                { return "text" }
func (Text) Needs() []string             { return nil }
func (Text) Handles(mime, _ string) bool { return extract.Text(mime) }

func (Text) Extract(_ context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{}

	body, err := textOf(in, out)
	if err != nil {
		return nil, err
	}

	out.Set("text", out.Capped(strings.TrimSpace(body)))

	return out, nil
}
