package rich

import (
	"strings"
	"unicode/utf8"
)

func length(s string) int {
	return utf8.RuneCountInString(s)
}

func valid(s string) string {
	return strings.ToValidUTF8(s, "�")
}

func nonEmpty(values ...string) []string {
	held := []string{}

	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			held = append(held, value)
		}
	}

	return held
}
