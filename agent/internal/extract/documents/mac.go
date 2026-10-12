package documents

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	LocatedOnMac = "imageio"
	pageBreak    = "\f"
)

func init() {
	if extract.OnMac {
		extract.Prefer(MacPdf{})
		extract.Prefer(MacImage{})
		extract.Prefer(MacDoc{})
	}
}

type MacPdf struct{}

func (MacPdf) Name() string { return "pdf" }

func (MacPdf) Handles(mime, _ string) bool { return mime == "application/pdf" }

func (MacPdf) Needs() []string { return []string{extract.MacProgram()} }

type macPages struct {
	Info    map[string]any `json:"info"`
	Pages   []string       `json:"pages"`
	Outline []struct {
		Name string `json:"name"`
		Page int    `json:"page"`
	} `json:"outline"`
}

type macRead struct {
	Pages []struct {
		Page int    `json:"page"`
		Text string `json:"text"`
	} `json:"pages"`
	Of int `json:"of"`
}

func (MacPdf) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	s := begin(ctx, in, "pdf")

	var read macPages
	err := s.mac(&read, "pdf", in.Path)
	if err != nil {
		s.keep("info", "", nil, err)
	} else {
		s.keep("info", "", numbered(read.Info), nil)
	}

	if s.wanted("text") {
		text, outline, textErr := s.macPdfText(in.Path, read, err)
		s.keep("text", PdfReads, text, textErr)

		if len(outline) > 0 {
			s.keep("outline", "", outline, nil)
		}
	}

	return s.finish(), ctx.Err()
}

func numbered(info map[string]any) map[string]any {
	for key, value := range info {
		if number, ok := value.(json.Number); ok {
			if whole, err := number.Int64(); err == nil {
				info[key] = int(whole)
			}
		}
	}

	return info
}

func (s *session) mac(into any, command, input string, options ...string) error {
	return extract.AskMac(s.ctx, s.in.Run, Patience, into, command, input, options...)
}

func (s *session) macPdfText(pdf string, read macPages, readErr error) (string, []extract.Section, error) {
	pages := len(read.Pages)
	layered := strings.TrimSpace(strings.Join(read.Pages, pageBreak))

	if readErr == nil && !sparse(layered, pages) {
		return s.capped(layered), PageOutline(read, layered, MaxText), nil
	}

	recognized, ocrErr := s.macRecognized(pdf, pages)
	if strings.TrimSpace(recognized) != "" {
		return s.capped(recognized), nil, nil
	}

	if layered == "" && readErr != nil {
		return "", nil, readErr
	}

	if layered == "" && ocrErr != nil {
		return "", nil, ocrErr
	}

	return s.capped(layered), PageOutline(read, layered, MaxText), nil
}

func (s *session) macRecognized(pdf string, pages int) (string, error) {
	last := OcrPages
	if pages > 0 {
		last = min(pages, OcrPages)
	}

	var read macRead
	if err := s.mac(&read, "ocr", pdf, "--kind", "pdf", "--pages", strconv.Itoa(last)); err != nil {
		return "", err
	}

	if read.Of > OcrPages {
		s.leave("pages", fmt.Sprintf("OCR read the first %d of its %d pages", OcrPages, read.Of))
	}

	texts := []string{}
	for _, page := range read.Pages {
		texts = append(texts, strings.TrimSpace(page.Text))
	}

	return strings.TrimSpace(strings.Join(texts, pageBreak)), nil
}

func PageOutline(read macPages, text string, most int) []extract.Section {
	if len(read.Outline) == 0 {
		return nil
	}

	starts := []int{0}
	at := 0
	for _, page := range read.Pages {
		at += utf8.RuneCountInString(page) + 1
		starts = append(starts, at)
	}

	lead := utf8.RuneCountInString(strings.Join(read.Pages, pageBreak)) - utf8.RuneCountInString(strings.TrimLeft(strings.Join(read.Pages, pageBreak), " \t\r\n\f\v"))
	length := min(utf8.RuneCountInString(text), most)
	sections := []extract.Section{}

	for _, entry := range read.Outline {
		if entry.Page < 1 || entry.Page > len(read.Pages) || len(sections) >= extract.MostSections {
			continue
		}

		from := max(starts[entry.Page-1]-lead, 0)
		if from >= length {
			continue
		}

		sections = append(sections, extract.Section{Name: extract.Truncate(extract.Squish(entry.Name), 80), From: from})
	}

	return sections
}

type MacImage struct{}

func (MacImage) Name() string { return "image" }

func (MacImage) Handles(mime, _ string) bool { return strings.HasPrefix(mime, "image/") }

func (MacImage) Needs() []string { return []string{extract.MacProgram()} }

func (MacImage) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	s := begin(ctx, in, "image")

	var seen struct {
		Width     int                `json:"width"`
		Height    int                `json:"height"`
		Frames    int                `json:"frames"`
		Deviation json.Number        `json:"deviation"`
		Location  map[string]float64 `json:"location"`
	}

	err := s.mac(&seen, "image", in.Path)

	if s.wanted("dimensions") {
		s.keep("dimensions", "", map[string]int{"width": seen.Width, "height": seen.Height}, err)
	}

	if s.wanted("deviation") {
		spread, parseErr := seen.Deviation.Float64()
		if err != nil {
			parseErr = err
		}
		s.keep("deviation", "", round6(spread), parseErr)
	}

	frames := max(seen.Frames, 1)
	if animatable[in.MIME] {
		s.keep("frames", "", frames, nil)
	}

	if s.wanted("location") {
		var located any
		if seen.Location != nil {
			located = seen.Location
		}
		s.keep("location", LocatedOnMac, located, err)
	}

	if s.wanted("ocr") {
		var read macRead
		ocrErr := s.mac(&read, "ocr", in.Path)
		text := ""
		if len(read.Pages) > 0 {
			text = read.Pages[0].Text
		}
		s.keep("ocr", "", s.capped(strings.TrimSpace(text)), ocrErr)
	}

	if animatable[in.MIME] && frames > 1 {
		s.macFrames(in.Path, frames)
	}

	return s.finish(), ctx.Err()
}

func (s *session) macFrames(path string, frames int) {
	set := s.in.Set.Settled()
	picked := Picked(frames, set.Frames, set.Share)
	listed := make([]string, len(picked))

	for at, page := range picked {
		listed[at] = strconv.Itoa(page)
	}

	var made struct {
		Frames []struct {
			Index int    `json:"index"`
			Path  string `json:"path"`
		} `json:"frames"`
	}

	if err := s.mac(&made, "frames", path, "--index", strings.Join(listed, ","), "--width", strconv.Itoa(FrameWidth), "--out", s.in.Work); err != nil {
		s.leave("frames", "the animation's frames could not be drawn")

		return
	}

	for _, frame := range made.Frames {
		s.out.Files = append(s.out.Files, extract.File{
			Role: "frame",
			Name: fmt.Sprintf("frame-%d.jpg", frame.Index),
			MIME: "image/jpeg",
			Path: frame.Path,
		})
	}

	if len(made.Frames) < len(picked) {
		s.leave("frames", fmt.Sprintf("%d of %d frames could not be drawn", len(picked)-len(made.Frames), len(picked)))
	}
}

const MacDocReads = "headings and tables from the document itself, else textutil's text"

var macDocTypes = map[string]bool{
	"application/msword":       true,
	Docx:                       true,
	Odt:                        true,
	"application/rtf":          true,
	"text/rtf":                 true,
	"application/x-webarchive": true,
}

type MacDoc struct{}

func (MacDoc) Name() string { return "doc" }

func (MacDoc) Handles(mime, _ string) bool { return macDocTypes[mime] }

func (MacDoc) Needs() []string { return []string{"textutil"} }

func (MacDoc) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	s := begin(ctx, in, "doc")
	format := extract.TextutilFormat(in.MIME, in.Name)

	said, infoErr := s.run(Patience, "textutil", "-info", "-format", format, in.Path)
	info := map[string]any{}
	for _, tag := range extract.TextutilInfo(said) {
		switch tag.Name {
		case "Title", "Author":
			info[strings.ToLower(tag.Name)] = tag.Value
		}
	}
	if infoErr != nil && len(info) == 0 {
		s.keep("info", "", nil, infoErr)
	} else {
		s.keep("info", "", info, nil)
	}

	if !s.wanted("text") {
		return s.finish(), ctx.Err()
	}

	if ReadsWordprocessing(in.MIME) {
		if headed := WordprocessingText(in.Path, in.MIME); headed != "" {
			s.keep("text", MacDocReads, s.capped(headed), nil)

			return s.finish(), ctx.Err()
		}
	}

	text, err := s.run(Patience, "textutil", "-format", format, "-convert", "txt", "-encoding", "UTF-8", "-stdout", in.Path)
	s.keep("text", MacDocReads, s.capped(strings.TrimSpace(text)), err)

	return s.finish(), ctx.Err()
}
