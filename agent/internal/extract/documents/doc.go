package documents

import (
	"context"
	"errors"
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
	named := filepath.Join(dir, "document"+filepath.Ext(s.in.Name))
	if err := os.Symlink(source, named); err != nil {
		return "", err
	}
	profile := "file://" + filepath.Join(dir, "profile")
	if _, err := s.run(Patience, "soffice", "-env:UserInstallation="+profile, "--headless", "--norestore",
		"--convert-to", "pdf", "--outdir", dir, named); err != nil {
		return "", err
	}
	made, _ := filepath.Glob(filepath.Join(dir, "*.pdf"))
	if len(made) == 0 {
		return "", errors.New("libreoffice produced no pdf")
	}
	return made[0], nil
}
