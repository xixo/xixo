package rich

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"

	"github.com/xixo/xixo/link/internal/extract"
)

const (
	container    = "META-INF/container.xml"
	encryption   = "META-INF/encryption.xml"
	mostEntry    = 8 << 20
	mostChapters = 1_000
	mostEntries  = 20_000
	mostUnzipped = 512 << 20
)

var chapterBlocks = map[atom.Atom]bool{
	atom.P: true, atom.Div: true, atom.H1: true, atom.H2: true, atom.H3: true, atom.H4: true,
	atom.H5: true, atom.H6: true, atom.Li: true, atom.Br: true, atom.Tr: true, atom.Blockquote: true,
	atom.Section: true, atom.Article: true, atom.Pre: true,
}

type Epub struct{}

func (Epub) Name() string { return "epub" }

func (Epub) Handles(mime, name string) bool { return mime == "application/epub+zip" }

func (Epub) Needs() []string { return nil }

type Book struct {
	Title        string   `json:"title,omitempty"`
	Publisher    string   `json:"publisher,omitempty"`
	Date         string   `json:"date,omitempty"`
	Language     string   `json:"language,omitempty"`
	Identifier   string   `json:"identifier,omitempty"`
	Description  string   `json:"description,omitempty"`
	Creators     []string `json:"creators,omitempty"`
	Contributors []string `json:"contributors,omitempty"`
	Subjects     []string `json:"subjects,omitempty"`
	Chapters     []string `json:"chapters,omitempty"`
	Encrypted    []string `json:"encrypted,omitempty"`
}

type archive struct {
	reader   *zip.ReadCloser
	files    map[string]*zip.File
	unzipped int64
}

var errTooLarge = errors.New("the epub holds more than can be read")

func openArchive(name string) (*archive, error) {
	reader, err := zip.OpenReader(name)
	if err != nil {
		return nil, err
	}

	if len(reader.File) > mostEntries {
		reader.Close()

		return nil, fmt.Errorf("it holds more than %s entries", extract.Delimited(mostEntries))
	}

	files := map[string]*zip.File{}
	for _, file := range reader.File {
		if _, held := files[file.Name]; !held {
			files[file.Name] = file
		}
	}

	return &archive{reader: reader, files: files}, nil
}

func (a *archive) read(name string, most int64) ([]byte, error) {
	file, ok := a.files[name]
	if !ok || file.FileInfo().IsDir() {
		return nil, nil
	}

	if most <= 0 || a.unzipped >= mostUnzipped {
		return nil, errTooLarge
	}

	opened, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	room := min(most, mostUnzipped-a.unzipped)
	held, err := io.ReadAll(io.LimitReader(opened, room+1))
	a.unzipped += int64(len(held))

	if err != nil {
		return nil, err
	}

	if int64(len(held)) > room {
		return nil, fmt.Errorf("%s is larger than %d MB", name, most>>20)
	}

	return held, nil
}

func (Epub) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{Extractor: "epub"}

	book, err := openArchive(in.Path)
	if err != nil {
		return nil, fmt.Errorf("unreadable epub: %s", extract.Truncate(err.Error(), 200))
	}
	defer book.reader.Close()

	described, err := book.describe()
	if err != nil {
		return nil, err
	}

	out.Set("book", described)

	chapters := book.chapters(ctx, described)
	text := strings.Join(nonEmpty(facts(described), chapters), "\n\n")
	out.Set("text", out.Capped(text))

	return out, nil
}

func (a *archive) describe() (*Book, error) {
	root, err := a.packagePath()
	if err != nil {
		return nil, err
	}

	body, err := a.read(root, mostEntry)
	if err != nil {
		return nil, fmt.Errorf("unreadable epub: %s", extract.Truncate(err.Error(), 200))
	}

	if body == nil {
		return nil, fmt.Errorf("%s is missing from the epub", root)
	}

	parsed := parsePackage(body)
	book := &Book{
		Title:        first(parsed.metadata["title"]),
		Publisher:    first(parsed.metadata["publisher"]),
		Date:         first(parsed.metadata["date"]),
		Language:     first(parsed.metadata["language"]),
		Identifier:   first(parsed.metadata["identifier"]),
		Description:  first(parsed.metadata["description"]),
		Creators:     parsed.metadata["creator"],
		Contributors: parsed.metadata["contributor"],
		Subjects:     parsed.metadata["subject"],
		Encrypted:    a.encrypted(),
	}

	base := path.Dir(root)
	seen := map[string]bool{}

	for _, idref := range parsed.spine {
		item, ok := parsed.items[idref]
		if !ok || !strings.Contains(item.mediaType, "html") || item.href == "" {
			continue
		}

		chapter := inside(base, item.href)
		if seen[chapter] {
			continue
		}

		seen[chapter] = true
		book.Chapters = append(book.Chapters, chapter)

		if len(book.Chapters) == mostChapters {
			break
		}
	}

	return book, nil
}

func first(values []string) string {
	if len(values) == 0 {
		return ""
	}

	return values[0]
}

func (a *archive) packagePath() (string, error) {
	if body, err := a.read(container, mostEntry); err == nil && body != nil {
		decoder := xml.NewDecoder(bytes.NewReader(body))
		decoder.Strict = false

		for {
			token, err := decoder.Token()
			if err != nil {
				break
			}

			if start, ok := token.(xml.StartElement); ok && start.Name.Local == "rootfile" {
				for _, attr := range start.Attr {
					if attr.Name.Local == "full-path" && attr.Value != "" {
						return attr.Value, nil
					}
				}
			}
		}
	}

	for _, file := range a.reader.File {
		if strings.HasSuffix(file.Name, ".opf") {
			return file.Name, nil
		}
	}

	return "", errors.New("the epub names no package document")
}

type manifestItem struct {
	href      string
	mediaType string
}

type packageDocument struct {
	metadata map[string][]string
	items    map[string]manifestItem
	spine    []string
}

var listedFields = map[string]bool{"creator": true, "contributor": true, "subject": true}

var singleFields = map[string]bool{
	"title": true, "publisher": true, "date": true, "language": true, "identifier": true, "description": true,
}

func parsePackage(body []byte) packageDocument {
	held := packageDocument{metadata: map[string][]string{}, items: map[string]manifestItem{}}
	decoder := xml.NewDecoder(bytes.NewReader(body))
	decoder.Strict = false
	decoder.AutoClose = xml.HTMLAutoClose
	decoder.Entity = xml.HTMLEntity

	inMetadata := false
	field := ""
	var text strings.Builder

	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}

		switch t := token.(type) {
		case xml.StartElement:
			local := t.Name.Local

			switch {
			case local == "metadata":
				inMetadata = true
			case inMetadata && field == "" && (listedFields[local] || singleFields[local]):
				field = local
				text.Reset()
			case local == "item":
				held.items[attr(t, "id")] = manifestItem{href: attr(t, "href"), mediaType: attr(t, "media-type")}
			case local == "itemref":
				held.spine = append(held.spine, attr(t, "idref"))
			}
		case xml.CharData:
			if field != "" && text.Len() < mostEntry {
				text.Write(t)
			}
		case xml.EndElement:
			switch {
			case t.Name.Local == "metadata":
				inMetadata = false
			case t.Name.Local == field:
				value := extract.Squish(valid(text.String()))
				if field == "description" {
					value = extract.Markup(value)
				}

				if value != "" && (listedFields[field] || len(held.metadata[field]) == 0) {
					held.metadata[field] = append(held.metadata[field], extract.Truncate(value, 4_000))
				}

				field = ""
			}
		}
	}

	return held
}

func attr(start xml.StartElement, name string) string {
	for _, a := range start.Attr {
		if a.Name.Local == name {
			return a.Value
		}
	}

	return ""
}

func (a *archive) encrypted() []string {
	body, err := a.read(encryption, mostEntry)
	if err != nil || body == nil {
		return nil
	}

	listed := []string{}
	decoder := xml.NewDecoder(bytes.NewReader(body))
	decoder.Strict = false

	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}

		if start, ok := token.(xml.StartElement); ok && start.Name.Local == "CipherReference" {
			if uri := attr(start, "URI"); uri != "" {
				listed = append(listed, inside(".", uri))
			}
		}
	}

	return listed
}

func inside(base, href string) string {
	held, _, _ := strings.Cut(href, "#")
	if unescaped, err := url.QueryUnescape(held); err == nil {
		held = unescaped
	}

	return strings.TrimPrefix(path.Clean(path.Join(base, held)), "./")
}

func (a *archive) chapters(ctx context.Context, book *Book) string {
	skipped := map[string]bool{}
	for _, name := range book.Encrypted {
		skipped[name] = true
	}

	collected := []string{}
	total := 0

	for _, chapter := range book.Chapters {
		if total >= extract.MostText || ctx.Err() != nil {
			break
		}

		if skipped[chapter] {
			continue
		}

		body, err := a.read(chapter, mostEntry)
		if errors.Is(err, errTooLarge) {
			break
		}

		if err != nil || body == nil {
			continue
		}

		text := chapterText(body)
		if text == "" {
			continue
		}

		collected = append(collected, text)
		total += length(text)
	}

	return strings.Join(collected, "\n\n")
}

func chapterText(body []byte) string {
	document, err := html.Parse(strings.NewReader(extract.Readable(body)))
	if err != nil {
		return ""
	}

	root := findBody(document)
	if root == nil {
		root = document
	}

	var out strings.Builder
	walkText(root, &out)

	lines := []string{}
	for _, line := range strings.Split(out.String(), "\n") {
		if said := extract.Squish(line); said != "" {
			lines = append(lines, said)
		}
	}

	return valid(strings.Join(lines, "\n"))
}

func findBody(node *html.Node) *html.Node {
	if node.Type == html.ElementNode && node.DataAtom == atom.Body {
		return node
	}

	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if found := findBody(child); found != nil {
			return found
		}
	}

	return nil
}

func walkText(node *html.Node, out *strings.Builder) {
	if node.Type == html.ElementNode && (node.DataAtom == atom.Script || node.DataAtom == atom.Style) {
		return
	}

	if node.Type == html.TextNode {
		out.WriteString(node.Data)
	}

	for child := node.FirstChild; child != nil; child = child.NextSibling {
		walkText(child, out)
	}

	if node.Type == html.ElementNode && chapterBlocks[node.DataAtom] {
		out.WriteString("\n")
	}
}

func facts(book *Book) string {
	lines := []string{}
	add := func(label, value string) {
		if value != "" {
			lines = append(lines, label+value)
		}
	}

	add("Title: ", book.Title)
	add("By: ", strings.Join(book.Creators, ", "))
	add("With: ", strings.Join(book.Contributors, ", "))
	add("Publisher: ", book.Publisher)
	add("Published: ", book.Date)
	add("Language: ", book.Language)
	add("Subjects: ", strings.Join(book.Subjects, ", "))
	add("Description: ", book.Description)

	if encryptedThroughout(book) {
		lines = append(lines, "Its chapters are encrypted, so only its details could be read.")
	}

	return strings.Join(lines, "\n")
}

func encryptedThroughout(book *Book) bool {
	if len(book.Chapters) == 0 {
		return false
	}

	encrypted := map[string]bool{}
	for _, name := range book.Encrypted {
		encrypted[name] = true
	}

	for _, chapter := range book.Chapters {
		if !encrypted[chapter] {
			return false
		}
	}

	return true
}

func init() {
	extract.Register(Epub{})
}
