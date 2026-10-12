package documents

import (
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/xixo/xixo/agent/internal/extract"
)

const DocReads = "headings and tables from the document itself, else the pdf's text"

var docTypes = map[string]bool{
	"application/msword": true,
	Docx:                 true,
	Odt:                  true,
}

type Doc struct{}

func (Doc) Name() string { return "doc" }

func (Doc) Handles(mime, _ string) bool { return docTypes[mime] }

func (Doc) Needs() []string { return []string{"soffice", "pdfinfo", "pdftotext"} }

func (Doc) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	s := begin(ctx, in, "doc")

	var headed string
	if ReadsWordprocessing(in.MIME) {
		headed = WordprocessingText(in.Path, in.MIME)
	}

	pdf, err := s.asPdf(in.Path)
	if err != nil {
		s.keep("info", "", nil, err)
	} else {
		s.info(pdf)
	}

	if s.wanted("text") {
		switch {
		case headed != "":
			s.keep("text", DocReads, s.capped(headed), nil)
		case err != nil:
			s.keep("text", DocReads, nil, err)
		default:
			said, textErr := s.run(Patience, "pdftotext", "-q", pdf, "-")
			s.keep("text", DocReads, s.capped(strings.TrimSpace(said)), textErr)
		}
	}
	return s.finish(), ctx.Err()
}

func (s *session) asPdf(source string) (string, error) {
	dir, err := os.MkdirTemp(s.in.Work, "office-")
	if err != nil {
		return "", err
	}
	named := filepath.Join(dir, "document"+strings.ToLower(filepath.Ext(s.in.Name)))
	if err := placed(source, named); err != nil {
		return "", err
	}
	outdir := filepath.Join(dir, "out")
	if err := os.Mkdir(outdir, 0o700); err != nil {
		return "", err
	}
	profile := (&url.URL{Scheme: "file", Path: filepath.Join(dir, "profile")}).String()
	said, err := s.run(Patience, "soffice", "-env:UserInstallation="+profile, "--headless", "--norestore",
		"--convert-to", "pdf", "--outdir", outdir, named)
	if err != nil {
		return "", err
	}
	made, _ := filepath.Glob(filepath.Join(outdir, "*.pdf"))
	if len(made) == 0 {
		return "", fmt.Errorf("libreoffice produced no pdf: %s", strings.TrimSpace(said))
	}
	return made[0], nil
}

func placed(source, named string) error {
	if err := os.Link(source, named); err == nil {
		return nil
	}
	from, err := os.Open(source)
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := os.OpenFile(named, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(to, from); err != nil {
		to.Close()
		return err
	}
	return to.Close()
}
