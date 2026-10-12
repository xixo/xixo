package documents

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	OcrPages = 30
	OcrDPI   = "200"
	Sparse   = 40
	PdfReads = "text layer, then ocr past 40 characters a page"
)

var infoFields = map[string]bool{"pages": true, "title": true, "author": true, "creationdate": true, "page_size": true}

type Pdf struct{}

func (Pdf) Name() string { return "pdf" }

func (Pdf) Handles(mime, _ string) bool { return mime == "application/pdf" }

func (Pdf) Needs() []string { return []string{"pdfinfo", "pdftotext", "pdftoppm", "tesseract"} }

func (Pdf) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	s := begin(ctx, in, "pdf")
	info := s.info(in.Path)
	if s.wanted("text") {
		text, err := s.pdfText(in.Path, pageCount(info))
		s.keep("text", PdfReads, text, err)
	}
	return s.finish(), ctx.Err()
}

func (s *session) info(pdf string) map[string]any {
	said, err := s.run(Patience, "pdfinfo", pdf)
	info := ParseInfo(said)
	if err != nil && len(info) == 0 {
		s.keep("info", "", nil, err)
		return nil
	}
	s.keep("info", "", info, nil)
	return info
}

func ParseInfo(output string) map[string]any {
	info := map[string]any{}
	for _, line := range strings.Split(output, "\n") {
		field, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		key := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(field)), " ", "_")
		if !infoFields[key] {
			continue
		}
		value = strings.TrimSpace(value)
		if key == "pages" {
			if n, err := strconv.Atoi(value); err == nil {
				info[key] = n
				continue
			}
		}
		info[key] = value
	}
	return info
}

func pageCount(info map[string]any) int {
	n, _ := info["pages"].(int)
	return n
}

func (s *session) pdfText(pdf string, pages int) (string, error) {
	said, err := s.run(Patience, "pdftotext", "-q", pdf, "-")
	layered := strings.TrimSpace(said)
	if err != nil && layered == "" && pages == 0 {
		return "", err
	}
	if !sparse(layered, pages) {
		return s.capped(layered), nil
	}
	recognized, ocrErr := s.recognized(pdf, pages)
	if strings.TrimSpace(recognized) != "" {
		return s.capped(recognized), nil
	}
	if layered == "" && err != nil {
		return "", err
	}
	if layered == "" && ocrErr != nil {
		return "", ocrErr
	}
	return s.capped(layered), nil
}

func sparse(text string, pages int) bool {
	count := 0
	for _, r := range text {
		if !unicode.IsSpace(r) {
			count++
		}
	}
	return count < Sparse*max(pages, 1)
}

func (s *session) recognized(pdf string, pages int) (string, error) {
	last := OcrPages
	if pages > 0 {
		last = min(pages, OcrPages)
	}
	if pages > OcrPages {
		s.leave("pages", fmt.Sprintf("OCR read the first %d of its %d pages", OcrPages, pages))
	}

	dir, err := os.MkdirTemp(s.in.Work, "ocr-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)

	var read []string
	var failed error
	rendered := 0
	for page := 1; page <= last; page++ {
		if err := s.ctx.Err(); err != nil {
			return "", err
		}
		prefix := filepath.Join(dir, "page")
		number := strconv.Itoa(page)
		if _, err := s.run(Patience, "pdftoppm", "-r", OcrDPI, "-gray", "-png", "-f", number, "-l", number, "-singlefile", pdf, prefix); err != nil {
			failed = err
			if pages == 0 && rendered > 0 {
				break
			}
			continue
		}
		rendered++
		said, err := s.run(Patience, "tesseract", prefix+".png", "stdout")
		os.Remove(prefix + ".png")
		if err != nil {
			continue
		}
		if text := strings.TrimSpace(said); text != "" {
			read = append(read, text)
		}
	}
	if rendered == 0 && failed != nil {
		return "", failed
	}
	return strings.Join(read, "\n\n"), nil
}
