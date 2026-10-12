package extract

import (
	"io"
	"regexp"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

var blocks = map[atom.Atom]bool{
	atom.P: true, atom.Div: true, atom.Br: true, atom.Li: true, atom.Ul: true, atom.Ol: true,
	atom.Tr: true, atom.Table: true, atom.Section: true, atom.Article: true, atom.Header: true,
	atom.Footer: true, atom.Blockquote: true, atom.Pre: true, atom.Hr: true, atom.Dt: true, atom.Dd: true,
}

var headings = map[atom.Atom]int{
	atom.H1: 1, atom.H2: 2, atom.H3: 3, atom.H4: 4, atom.H5: 5, atom.H6: 6,
}

var (
	runs       = regexp.MustCompile(`[ \t\r\v\f\x{00A0}]+`)
	edges      = regexp.MustCompile(` *\n *`)
	paragraphs = regexp.MustCompile(`\n{3,}`)
)

const mostMarkup = 32 << 20

func Markup(source string) string {
	tokens := html.NewTokenizer(io.LimitReader(strings.NewReader(source), mostMarkup))
	tokens.SetMaxBuf(4 << 20)

	var out strings.Builder
	var heading strings.Builder
	level := 0
	hidden := 0
	blocked := false

	write := func(s string) {
		if strings.TrimSpace(s) != "" {
			blocked = false
		}

		if level > 0 {
			heading.WriteString(s)
		} else {
			out.WriteString(s)
		}
	}

	block := func() {
		if !blocked {
			write("\n")
			blocked = true
		}
	}

	for {
		kind := tokens.Next()
		if kind == html.ErrorToken {
			break
		}

		token := tokens.Token()

		switch kind {
		case html.StartTagToken, html.SelfClosingTagToken:
			switch {
			case token.DataAtom == atom.Script || token.DataAtom == atom.Style:
				if kind == html.StartTagToken {
					hidden++
				}
			case headings[token.DataAtom] > 0 && level == 0 && kind == html.StartTagToken:
				level = headings[token.DataAtom]
				heading.Reset()
			case blocks[token.DataAtom]:
				block()
			default:
				write(" ")
			}
		case html.EndTagToken:
			switch {
			case token.DataAtom == atom.Script || token.DataAtom == atom.Style:
				if hidden > 0 {
					hidden--
				}
			case headings[token.DataAtom] == level && level > 0:
				named := Squish(heading.String())
				out.WriteString("\n\n" + strings.Repeat("#", level) + " " + named + "\n\n")
				level = 0
				blocked = false
			case blocks[token.DataAtom]:
				block()
			default:
				write(" ")
			}
		case html.TextToken:
			if hidden == 0 {
				write(token.Data)
			}
		}
	}

	if level > 0 {
		out.WriteString(heading.String())
	}

	text := runs.ReplaceAllString(out.String(), " ")
	text = edges.ReplaceAllString(text, "\n")
	text = paragraphs.ReplaceAllString(text, "\n\n")

	return strings.TrimSpace(text)
}
