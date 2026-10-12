package plain

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/xixo/xixo/link/internal/extract"
)

const (
	sniff      = 8_192
	control    = 0.01
	tarMagicAt = 257
	MostListed = 200
)

var (
	markupName = regexp.MustCompile(`(?i)\.(html?|xhtml|svg|xml)\z`)
	magic      = []struct {
		prefix string
		name   string
	}{
		{"PK\x03\x04", "zip"}, {"\x1f\x8b", "gzip"}, {"%PDF", "pdf"}, {"\x7fELF", "executable"},
		{"ID3", "audio"}, {"OggS", "audio"}, {"RIFF", "media"}, {"\x89PNG", "image"},
	}
)

type Fallback struct{}

func (Fallback) Name() string             { return "fallback" }
func (Fallback) Needs() []string          { return nil }
func (Fallback) Handles(_, _ string) bool { return true }

type Format struct {
	Declared  string `json:"declared"`
	Observed  string `json:"observed"`
	Printable bool   `json:"printable"`
}

func (Fallback) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{}

	info, err := os.Stat(in.Path)
	if err != nil {
		return nil, err
	}

	head, err := headOf(in.Path)
	if err != nil {
		return nil, err
	}

	printable := legible(head)
	observed := observe(head, printable)

	out.Set("size", map[string]int64{"bytes": info.Size()})
	out.Set("format", Format{Declared: in.MIME, Observed: observed, Printable: printable})

	if printable {
		body, err := textOf(in, out)
		if err != nil {
			return nil, err
		}

		if markupName.MatchString(in.Name) || strings.HasPrefix(strings.TrimLeft(body, " \t\r\n"), "<") {
			body = extract.Markup(body)
		}

		out.Set("text", out.Capped(strings.TrimSpace(body)))
	}

	if archived(observed, head) {
		listed, err := entries(ctx, in.Path, observed)
		if err != nil {
			out.Fail("listing", fmt.Errorf("unreadable archive: %s", extract.Truncate(err.Error(), 200)))
		} else {
			out.Set("listing", listed)
		}
	}

	return out, nil
}

func headOf(name string) ([]byte, error) {
	opened, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	head := make([]byte, sniff)
	count, err := io.ReadFull(opened, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, err
	}

	return head[:count], nil
}

func observe(head []byte, printable bool) string {
	for _, known := range magic {
		if bytes.HasPrefix(head, []byte(known.prefix)) {
			return known.name
		}
	}

	if tarred(head) {
		return "tar"
	}

	if printable {
		return "text"
	}

	return "binary"
}

func legible(sample []byte) bool {
	if len(bytes.TrimSpace(sample)) == 0 {
		return false
	}

	text, ok := validPrefix(sample)
	if !ok {
		return false
	}

	controls := 0
	for _, char := range text {
		if (char <= 0x08) || char == 0x0b || char == 0x0c || (char >= 0x0e && char <= 0x1f) {
			controls++
		}
	}

	return float64(controls)/float64(utf8.RuneCountInString(text)) < control
}

func validPrefix(sample []byte) (string, bool) {
	for dropped := 0; dropped < 3 && dropped < len(sample); dropped++ {
		held := sample[:len(sample)-dropped]
		if utf8.Valid(held) && len(held) > 0 {
			return string(held), true
		}
	}

	return "", false
}

func tarred(head []byte) bool {
	return len(head) >= tarMagicAt+5 && string(head[tarMagicAt:tarMagicAt+5]) == "ustar"
}

func archived(observed string, head []byte) bool {
	switch observed {
	case "zip", "tar":
		return true
	case "gzip":
		return tarred(inflated(head))
	default:
		return false
	}
}

func inflated(head []byte) []byte {
	reader, err := gzip.NewReader(bytes.NewReader(head))
	if err != nil {
		return nil
	}

	held := make([]byte, tarMagicAt+5)
	count, _ := io.ReadFull(reader, held)

	return held[:count]
}

func entries(ctx context.Context, name, observed string) ([]string, error) {
	if observed == "zip" {
		return zipped(ctx, name)
	}

	opened, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	var source io.Reader = &bounded{ctx: ctx, from: opened, left: MostInflated}

	if observed == "gzip" {
		unzipped, err := gzip.NewReader(source)
		if err != nil {
			return nil, err
		}
		defer unzipped.Close()

		source = &bounded{ctx: ctx, from: unzipped, left: MostInflated}
	}

	reader := tar.NewReader(source)
	listed := []string{}

	for len(listed) < MostListed {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}

		if errors.Is(err, errInflated) && len(listed) > 0 {
			break
		}

		if err != nil {
			return nil, err
		}

		if header.Typeflag == tar.TypeXHeader || header.Typeflag == tar.TypeXGlobalHeader ||
			strings.HasPrefix(path.Base(header.Name), "._") {
			continue
		}

		listed = append(listed, header.Name)
	}

	return listed, nil
}
