package documents

import (
	"archive/zip"
	"encoding/xml"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"
)

const (
	Docx     = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	Odt      = "application/vnd.oasis.opendocument.text"
	MostXML  = 50 << 20
	wordNS   = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
	officeNS = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
	textNS   = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
	tableNS  = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
)

var headingStyle = regexp.MustCompile(`(?i)\Aheading\s*(\d+)\z`)

type node struct {
	space, local string
	attrs        []xml.Attr
	children     []*node
	text         string
}

func (n *node) is(space, local string) bool {
	return n != nil && n.space == space && n.local == local
}

func (n *node) attr(space, local string) (string, bool) {
	for _, a := range n.attrs {
		if a.Name.Space == space && a.Name.Local == local {
			return a.Value, true
		}
	}
	return "", false
}

func (n *node) child(space, local string) *node {
	for _, c := range n.children {
		if c.is(space, local) {
			return c
		}
	}
	return nil
}

func (n *node) elements() []*node {
	var found []*node
	for _, c := range n.children {
		if c.local != "" {
			found = append(found, c)
		}
	}
	return found
}

func (n *node) walk(visit func(*node) bool) {
	for _, c := range n.children {
		if visit(c) {
			c.walk(visit)
		}
	}
}

func (n *node) find(space, local string) *node {
	var found *node
	n.walk(func(c *node) bool {
		if found != nil {
			return false
		}
		if c.is(space, local) {
			found = c
			return false
		}
		return true
	})
	return found
}

func (n *node) all(space, local string) []*node {
	var found []*node
	n.walk(func(c *node) bool {
		if c.is(space, local) {
			found = append(found, c)
		}
		return true
	})
	return found
}

func (n *node) content() string {
	if n.local == "" {
		return n.text
	}
	var b strings.Builder
	n.walk(func(c *node) bool {
		if c.local == "" {
			b.WriteString(c.text)
		}
		return true
	})
	return b.String()
}

func parseXML(r io.Reader) (*node, error) {
	decoder := xml.NewDecoder(r)
	decoder.Strict = false
	root := &node{}
	stack := []*node{root}
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return root, nil
		}
		if err != nil {
			return nil, err
		}
		top := stack[len(stack)-1]
		switch t := token.(type) {
		case xml.StartElement:
			el := &node{space: t.Name.Space, local: t.Name.Local, attrs: t.Attr}
			top.children = append(top.children, el)
			stack = append(stack, el)
		case xml.EndElement:
			if len(stack) > 1 {
				stack = stack[:len(stack)-1]
			}
		case xml.CharData:
			top.children = append(top.children, &node{text: string(t)})
		}
	}
}

func ReadsWordprocessing(mime string) bool {
	return mime == Docx || mime == Odt
}

func WordprocessingText(path, mime string) string {
	switch mime {
	case Docx:
		return docx(entry(path, "word/document.xml"))
	case Odt:
		return odt(entry(path, "content.xml"))
	}
	return ""
}

func entry(path, name string) *node {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return nil
	}
	defer archive.Close()
	for _, f := range archive.File {
		if f.Name != name {
			continue
		}
		if f.UncompressedSize64 > MostXML {
			return nil
		}
		r, err := f.Open()
		if err != nil {
			return nil
		}
		defer r.Close()
		root, err := parseXML(io.LimitReader(r, MostXML))
		if err != nil {
			return nil
		}
		return root
	}
	return nil
}

func docx(root *node) string {
	if root == nil {
		return ""
	}
	body := root.find(wordNS, "body")
	if body == nil {
		return ""
	}
	var blocks []string
	for _, c := range body.children {
		switch {
		case c.is(wordNS, "p"):
			blocks = append(blocks, docxParagraph(c))
		case c.is(wordNS, "tbl"):
			blocks = append(blocks, docxTable(c))
		}
	}
	return joined(blocks)
}

func docxParagraph(p *node) string {
	var b strings.Builder
	p.walk(func(c *node) bool {
		switch {
		case c.is(wordNS, "pPr"):
			return false
		case c.is(wordNS, "t"):
			b.WriteString(c.content())
			return false
		case c.is(wordNS, "tab"):
			b.WriteString("\t")
		case c.is(wordNS, "br"):
			b.WriteString("\n")
		}
		return true
	})
	said := strings.TrimSpace(b.String())
	if said == "" {
		return ""
	}
	if level := docxLevel(p); level > 0 {
		return strings.Repeat("#", level) + " " + squish(said)
	}
	return said
}

func docxLevel(p *node) int {
	props := p.child(wordNS, "pPr")
	if props == nil {
		return 0
	}
	style := ""
	if s := props.child(wordNS, "pStyle"); s != nil {
		style, _ = s.attr(wordNS, "val")
	}
	if strings.EqualFold(style, "Title") {
		return 1
	}
	if m := headingStyle.FindStringSubmatch(style); m != nil {
		n, _ := strconv.Atoi(m[1])
		return clamp(n)
	}
	if o := props.child(wordNS, "outlineLvl"); o != nil {
		if v, ok := o.attr(wordNS, "val"); ok {
			n, _ := strconv.Atoi(v)
			return clamp(n + 1)
		}
	}
	return 0
}

func docxTable(table *node) string {
	var rows []string
	for _, row := range table.children {
		if !row.is(wordNS, "tr") {
			continue
		}
		var cells []string
		for _, cell := range row.children {
			if !cell.is(wordNS, "tc") {
				continue
			}
			var b strings.Builder
			for _, t := range cell.all(wordNS, "t") {
				b.WriteString(t.content())
			}
			cells = append(cells, squish(b.String()))
		}
		rows = append(rows, strings.Join(cells, " | "))
	}
	return strings.Join(rows, "\n")
}

func odt(root *node) string {
	if root == nil {
		return ""
	}
	body := root.find(officeNS, "text")
	if body == nil {
		return ""
	}
	return joined(odtBlocks(body))
}

func odtBlocks(n *node) []string {
	var blocks []string
	for _, c := range n.elements() {
		switch c.local {
		case "h":
			blocks = append(blocks, odtHeading(c))
		case "p":
			blocks = append(blocks, strings.TrimSpace(c.content()))
		case "table":
			blocks = append(blocks, odtTable(c))
		case "list", "list-item", "section":
			blocks = append(blocks, odtBlocks(c)...)
		}
	}
	return blocks
}

func odtHeading(h *node) string {
	level := 1
	if v, ok := h.attr(textNS, "outline-level"); ok {
		n, _ := strconv.Atoi(v)
		level = clamp(n)
	}
	said := squish(h.content())
	if said == "" {
		return ""
	}
	return strings.Repeat("#", level) + " " + said
}

func odtTable(table *node) string {
	var rows []string
	for _, row := range table.all(tableNS, "table-row") {
		var cells []string
		for _, cell := range row.children {
			if cell.is(tableNS, "table-cell") {
				cells = append(cells, squish(cell.content()))
			}
		}
		rows = append(rows, strings.Join(cells, " | "))
	}
	return strings.Join(rows, "\n")
}

func clamp(n int) int {
	return min(max(n, 1), 6)
}

func joined(blocks []string) string {
	var kept []string
	for _, b := range blocks {
		if strings.TrimSpace(b) != "" {
			kept = append(kept, b)
		}
	}
	return strings.Join(kept, "\n\n")
}
