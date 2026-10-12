package documents

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/xixo/xixo/link/internal/extract"
)

const (
	MaxText   = 200_000
	Patience  = 10 * time.Minute
	Glance    = 30 * time.Second
	errLength = 200
)

func init() {
	extract.Register(Pdf{})
	extract.Register(Doc{})
	extract.Register(Image{})
}

type session struct {
	ctx context.Context
	in  extract.Input
	out *extract.Output
}

func begin(ctx context.Context, in extract.Input, name string) *session {
	return &session{ctx: ctx, in: in, out: &extract.Output{
		Extractor: name,
		Steps:     map[string]extract.Step{},
		Dropped:   map[string]string{},
	}}
}

func (s *session) wanted(name string) bool {
	return !s.in.Skip[name]
}

func (s *session) keep(name, digest string, result any, err error) {
	if err != nil {
		s.out.Steps[name] = extract.Step{Digest: digest, Error: brief(err.Error())}
		return
	}
	s.out.Steps[name] = extract.Step{Result: result, Digest: digest}
}

func (s *session) leave(what, said string) {
	s.out.Dropped[what] = said
}

func (s *session) finish() *extract.Output {
	if len(s.out.Dropped) == 0 {
		s.out.Dropped = nil
	}
	return s.out
}

func (s *session) run(limit time.Duration, program string, args ...string) (string, error) {
	if s.in.Run == nil {
		return "", errors.New("no runner")
	}
	out, err := s.in.Run.Run(s.ctx, limit, program, args...)
	if err != nil {
		return string(out), fmt.Errorf("%s failed: %w", program, err)
	}
	return string(out), nil
}

func (s *session) capped(text string) string {
	count := utf8.RuneCountInString(text)
	if count <= MaxText {
		return text
	}
	s.leave("text", fmt.Sprintf("only the first %s of %s characters were read", delimited(MaxText), delimited(count)))
	return truncate(text, MaxText)
}

func truncate(text string, limit int) string {
	const omission = "..."
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return string(runes[:limit-len(omission)]) + omission
}

func delimited(n int) string {
	digits := fmt.Sprint(n)
	var b strings.Builder
	for i, d := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(d)
	}
	return b.String()
}

func squish(text string) string {
	return strings.Join(strings.FieldsFunc(text, unicode.IsSpace), " ")
}

func brief(said string) string {
	said = strings.ToValidUTF8(strings.TrimSpace(said), "�")
	return truncate(said, errLength)
}
