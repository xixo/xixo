package rich

import (
	"archive/zip"
	"context"
	"encoding/xml"
	"errors"
	"io"
	"strconv"
	"strings"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	odsContent    = "content.xml"
	odsMimetype   = "mimetype"
	mostContent   = 512 << 20
	mostRepeated  = 10_000
	mostCellChars = 32 << 10
)

type odsBook struct {
	reader *zip.ReadCloser
	file   *zip.File
}

func opendocument(path string) bool {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return false
	}
	defer reader.Close()

	for _, file := range reader.File {
		if file.Name != odsMimetype {
			continue
		}

		opened, err := file.Open()
		if err != nil {
			return false
		}
		defer opened.Close()

		held, _ := io.ReadAll(io.LimitReader(opened, 128))

		return strings.TrimSpace(string(held)) == ods
	}

	return false
}

func openOds(path string) (workbook, error) {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}

	for _, file := range reader.File {
		if file.Name == odsContent {
			return odsBook{reader: reader, file: file}, nil
		}
	}

	reader.Close()

	return nil, errors.New("the spreadsheet has no content.xml")
}

func (b odsBook) Close() error { return b.reader.Close() }

type odsCell struct {
	value    any
	repeated int
}

type odsReading struct {
	row       int
	cells     []odsCell
	repeated  int
	cell      *odsCell
	kind      string
	text      strings.Builder
	paragraph int
	inCell    bool
}

func (b odsBook) walk(ctx context.Context, start func(string) error, visit func(int, []any)) error {
	opened, err := b.file.Open()
	if err != nil {
		return err
	}
	defer opened.Close()

	decoder := xml.NewDecoder(io.LimitReader(opened, mostContent))
	reading := &odsReading{}

	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}

		if err != nil {
			return err
		}

		switch t := token.(type) {
		case xml.StartElement:
			if err := reading.open(t, start); err != nil {
				return err
			}
		case xml.EndElement:
			reading.close(t, visit)
		case xml.CharData:
			if reading.inCell && reading.text.Len() < mostCellChars {
				reading.text.Write(t)
			}
		}
	}
}

func (r *odsReading) open(t xml.StartElement, start func(string) error) error {
	switch t.Name.Local {
	case "table":
		if t.Name.Space != tableSpace {
			return nil
		}

		r.row = 0

		return start(odsAttr(t, "name"))
	case "table-row":
		r.cells = r.cells[:0]
		r.repeated = max(1, odsNumber(t, "number-rows-repeated"))
	case "table-cell", "covered-table-cell":
		r.inCell = true
		r.kind = odsAttr(t, "value-type")
		r.text.Reset()
		r.paragraph = 0
		r.cell = &odsCell{repeated: max(1, odsNumber(t, "number-columns-repeated")), value: odsValue(t, r.kind)}
	case "p", "h":
		if r.inCell {
			if r.paragraph > 0 {
				r.text.WriteString("\n")
			}

			r.paragraph++
		}
	case "s":
		if r.inCell {
			r.text.WriteString(strings.Repeat(" ", min(max(1, odsNumber(t, "c")), 64)))
		}
	case "tab":
		if r.inCell {
			r.text.WriteString("\t")
		}
	case "line-break":
		if r.inCell {
			r.text.WriteString("\n")
		}
	}

	return nil
}

func (r *odsReading) close(t xml.EndElement, visit func(int, []any)) {
	switch t.Name.Local {
	case "table-cell", "covered-table-cell":
		if r.cell == nil {
			return
		}

		if r.cell.value == nil {
			if said := strings.TrimSpace(r.text.String()); said != "" {
				r.cell.value = extract.Truncate(valid(said), mostCell)
			}
		}

		if len(r.cells) <= mostColumns {
			r.cells = append(r.cells, *r.cell)
		}

		r.cell = nil
		r.inCell = false
	case "table-row":
		cells := expand(r.cells)

		if allEmpty(cells) {
			r.row += r.repeated

			return
		}

		for range min(r.repeated, mostRepeated) {
			r.row++
			if r.row > mostRows {
				return
			}

			visit(r.row, cells)
		}

		r.row += max(0, r.repeated-mostRepeated)
	}
}

const tableSpace = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

func expand(cells []odsCell) []any {
	held := []any{}

	for _, cell := range cells {
		if cell.value == nil {
			if len(held)+cell.repeated > mostColumns {
				held = append(held, make([]any, max(0, mostColumns+1-len(held)))...)

				continue
			}

			held = append(held, make([]any, cell.repeated)...)

			continue
		}

		for range min(cell.repeated, mostColumns+1) {
			held = append(held, cell.value)
		}
	}

	for len(held) > 0 && held[len(held)-1] == nil {
		held = held[:len(held)-1]
	}

	return held
}

func allEmpty(cells []any) bool {
	for _, cell := range cells {
		if cell != nil {
			return false
		}
	}

	return true
}

func odsValue(t xml.StartElement, kind string) any {
	switch kind {
	case "float", "percentage", "currency":
		value, err := strconv.ParseFloat(odsAttr(t, "value"), 64)
		if err != nil || !finite(value) {
			return nil
		}

		return numeric(value)
	case "date":
		date := odsAttr(t, "date-value")

		return strings.TrimSuffix(date, "T00:00:00")
	case "boolean":
		return odsAttr(t, "boolean-value") == "true"
	}

	return nil
}

func odsAttr(t xml.StartElement, name string) string {
	for _, a := range t.Attr {
		if a.Name.Local == name {
			return a.Value
		}
	}

	return ""
}

func odsNumber(t xml.StartElement, name string) int {
	held, err := strconv.Atoi(odsAttr(t, name))
	if err != nil || held < 0 {
		return 0
	}

	return held
}
