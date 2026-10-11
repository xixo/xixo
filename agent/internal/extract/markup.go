package extract

import (
	"fmt"
	"regexp"
	"strings"
)

var (
	scripts   = regexp.MustCompile(`(?is)<(script|style)[^>]*>.*?</(?:script|style)>`)
	blocks    = regexp.MustCompile(`(?i)(?:</?(?:p|div|br|li|ul|ol|tr|table|section|article|header|footer|blockquote|pre|hr|dt|dd)\b[^>]*>\s*)+`)
	headings  = regexp.MustCompile(`(?is)<h([1-6])\b[^>]*>(.*?)</h([1-6])>`)
	tags      = regexp.MustCompile(`<[^>]+>`)
	entities  = regexp.MustCompile(`(?i)&(#?\w+);`)
	spaces    = regexp.MustCompile(`[ \t\r\v]+`)
	edges     = regexp.MustCompile(` *\n *`)
	gaps      = regexp.MustCompile(`\n{3,}`)
	entityFor = map[string]string{"nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": `"`, "apos": "'", "#39": "'"}
)

func Markup(html string) string {
	html = scripts.ReplaceAllString(html, " ")
	html = blocks.ReplaceAllString(html, "\n")
	html = headings.ReplaceAllStringFunc(html, func(found string) string {
		parts := headings.FindStringSubmatch(found)
		if parts[1] != parts[3] {
			return found
		}

		level := int(parts[1][0] - '0')

		return fmt.Sprintf("\n\n%s %s\n\n", strings.Repeat("#", level), Squish(tags.ReplaceAllString(parts[2], " ")))
	})
	html = tags.ReplaceAllString(html, " ")
	html = entities.ReplaceAllStringFunc(html, func(found string) string {
		name := strings.ToLower(entities.FindStringSubmatch(found)[1])
		if held, ok := entityFor[name]; ok {
			return held
		}

		return " "
	})
	html = spaces.ReplaceAllString(html, " ")
	html = edges.ReplaceAllString(html, "\n")
	html = gaps.ReplaceAllString(html, "\n\n")

	return strings.TrimSpace(html)
}
