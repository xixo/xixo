package terminal

import (
	"io"
	"os"
	"strings"
	"unicode"
)

type Style struct {
	On bool
}

func For(w io.Writer) Style {
	file, ok := w.(*os.File)
	if !ok || os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return Style{}
	}

	return Style{On: Is(file)}
}

func Is(file *os.File) bool {
	info, err := file.Stat()

	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func (s Style) paint(code, text string) string {
	if !s.On || text == "" {
		return text
	}

	return "\x1b[" + code + "m" + text + "\x1b[0m"
}

func (s Style) Bold(text string) string { return s.paint("1", text) }

func (s Style) Dim(text string) string { return s.paint("2", text) }

func (s Style) Red(text string) string { return s.paint("1;31", text) }

func (s Style) Green(text string) string { return s.paint("32", text) }

func (s Style) Yellow(text string) string { return s.paint("33", text) }

func Printable(text string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Bidi_Control, r) {
			return -1
		}

		return r
	}, text)
}
