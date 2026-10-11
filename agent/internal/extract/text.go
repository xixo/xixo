package extract

import (
	"bytes"
	"fmt"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
)

const MostText = 200_000

func Readable(raw []byte) string {
	switch {
	case bytes.HasPrefix(raw, []byte{0xFF, 0xFE}):
		return wide(raw[2:], false)
	case bytes.HasPrefix(raw, []byte{0xFE, 0xFF}):
		return wide(raw[2:], true)
	}

	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})

	if utf8.Valid(raw) {
		return string(raw)
	}

	decoded, err := charmap.Windows1252.NewDecoder().Bytes(raw)
	if err != nil {
		return strings.ToValidUTF8(string(raw), "�")
	}

	return string(decoded)
}

func wide(raw []byte, big bool) string {
	units := make([]uint16, 0, len(raw)/2)

	for at := 0; at+1 < len(raw); at += 2 {
		if big {
			units = append(units, uint16(raw[at])<<8|uint16(raw[at+1]))
		} else {
			units = append(units, uint16(raw[at+1])<<8|uint16(raw[at]))
		}
	}

	if len(raw)%2 == 1 {
		units = append(units, 0xFFFD)
	}

	return string(utf16.Decode(units))
}

func (o *Output) Capped(text string) string {
	return o.CappedAt(text, MostText)
}

func (o *Output) CappedAt(text string, limit int) string {
	length := utf8.RuneCountInString(text)
	if length <= limit {
		return text
	}

	o.Drop("text", fmt.Sprintf("only the first %s of %s characters were read", Delimited(limit), Delimited(length)))

	return Truncate(text, limit)
}

func Truncate(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}

	if limit <= 3 {
		return string([]rune(text)[:limit])
	}

	return string([]rune(text)[:limit-3]) + "..."
}

func Delimited(n int) string {
	digits := fmt.Sprint(n)
	if n < 0 {
		return "-" + Delimited(-n)
	}

	var out strings.Builder

	for at, digit := range digits {
		if at > 0 && (len(digits)-at)%3 == 0 {
			out.WriteByte(',')
		}

		out.WriteRune(digit)
	}

	return out.String()
}

func Squish(text string) string {
	return strings.Join(strings.Fields(text), " ")
}
