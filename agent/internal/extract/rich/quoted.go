package rich

import (
	"regexp"
	"strings"
)

var (
	attribution  = regexp.MustCompile(`(?s)\AOn\b.{4,300}\bwrote:\s*\z`)
	original     = regexp.MustCompile(`(?i)\A-{2,}\s*(Original Message|Forwarded message)\s*-{2,}\s*\z`)
	outlookFrom  = regexp.MustCompile(`\A\*?From:\*?\s+\S`)
	outlookField = regexp.MustCompile(`\A\*?(Sent|Date|To|Subject|Cc):\*?\s`)
	quote        = regexp.MustCompile(`\A\s*>`)
	quoteMark    = regexp.MustCompile(`\A\s*> ?`)
)

type Split struct {
	Fresh   string
	Earlier string
}

func Quoted(text string) Split {
	lines := strings.SplitAfter(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}

	cut := cutAt(lines)
	whole := strings.TrimSpace(text)

	if cut < 0 {
		return Split{Fresh: whole}
	}

	fresh := strings.TrimSpace(strings.Join(lines[:cut], ""))
	if fresh == "" {
		return Split{Fresh: whole}
	}

	return Split{Fresh: fresh, Earlier: unquoted(lines[cut:])}
}

func cutAt(lines []string) int {
	for index := range lines {
		line := strings.TrimSpace(lines[index])
		next := ""

		if index+1 < len(lines) {
			next = strings.TrimSpace(lines[index+1])
		}

		joined := line + " " + next

		if strings.HasPrefix(line, "On ") && (attribution.MatchString(line) || attribution.MatchString(joined)) {
			return index
		}

		if original.MatchString(line) || outlookHeader(lines, index) || quotedToTheEnd(lines, index) {
			return index
		}
	}

	return -1
}

func outlookHeader(lines []string, index int) bool {
	if !outlookFrom.MatchString(strings.TrimSpace(lines[index])) {
		return false
	}

	count := 0

	for _, line := range lines[index+1 : min(index+5, len(lines))] {
		if outlookField.MatchString(strings.TrimSpace(line)) {
			count++
		}
	}

	return count >= 2
}

func quotedToTheEnd(lines []string, index int) bool {
	if !quote.MatchString(lines[index]) {
		return false
	}

	for _, line := range lines[index:] {
		if strings.TrimSpace(line) != "" && !quote.MatchString(line) {
			return false
		}
	}

	return true
}

func unquoted(lines []string) string {
	var out strings.Builder

	for _, line := range lines {
		out.WriteString(quoteMark.ReplaceAllString(line, ""))
	}

	return strings.TrimSpace(out.String())
}
