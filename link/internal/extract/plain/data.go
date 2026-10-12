package plain

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"slices"
	"strings"

	"github.com/xixo/xixo/link/internal/extract"
)

var dataTypes = []string{"application/json", "application/xml", "text/csv", "text/tab-separated-values"}

type Data struct{}

func (Data) Name() string                { return "data" }
func (Data) Needs() []string             { return nil }
func (Data) Handles(mime, _ string) bool { return slices.Contains(dataTypes, mime) }

type Shape struct {
	Format  string   `json:"format"`
	Keys    []string `json:"keys,omitempty"`
	Columns []string `json:"columns,omitempty"`
	Rows    *int     `json:"rows,omitempty"`
	Error   string   `json:"error,omitempty"`
}

func (Data) Extract(_ context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{}

	body, err := textOf(in, out)
	if err != nil {
		return nil, err
	}

	extension := strings.ToLower(filepath.Ext(in.Name))
	out.Set("shape", shapeOf(body, extension))

	if separator, ok := separators[extension]; ok {
		tables := []*extract.Table{}

		if rows, err := parseCSV(body, separator, extract.MostRows+1); err == nil {
			if table := extract.Framed(filepath.Base(in.Name), rows); table != nil {
				tables = append(tables, table)
			}
		}

		out.Set("tables", tables)
	}

	out.Set("text", out.Capped(strings.TrimSpace(body)))

	return out, nil
}

var separators = map[string]rune{".csv": ',', ".tsv": '\t'}

func shapeOf(body, extension string) Shape {
	switch extension {
	case ".json":
		keys, err := topKeys(body)
		if err != nil {
			return Shape{Format: "invalid", Error: extract.Truncate(err.Error(), 200)}
		}

		return Shape{Format: "json", Keys: keys}
	case ".csv", ".tsv":
		rows, err := parseCSV(body, separators[extension], -1)
		if err != nil {
			return Shape{Format: "invalid", Error: extract.Truncate(err.Error(), 200)}
		}

		columns := []string{}
		if len(rows) > 0 {
			for _, cell := range rows[0] {
				if cell == nil {
					columns = append(columns, "")
				} else {
					columns = append(columns, cell.(string))
				}
			}
		}

		count := max(len(rows)-1, 0)

		return Shape{Format: "csv", Columns: columns, Rows: &count}
	default:
		return Shape{Format: "unknown"}
	}
}

func topKeys(body string) ([]string, error) {
	decoder := json.NewDecoder(strings.NewReader(body))

	first, err := decoder.Token()
	if err != nil {
		return nil, err
	}

	keys := []string{}

	if first != json.Delim('{') {
		var rest any
		if delim, ok := first.(json.Delim); ok && delim == '[' {
			for decoder.More() {
				if err := decoder.Decode(&rest); err != nil {
					return nil, err
				}
			}

			if _, err := decoder.Token(); err != nil {
				return nil, err
			}
		}

		return keys, trailing(decoder)
	}

	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return nil, err
		}

		var skipped json.RawMessage
		if err := decoder.Decode(&skipped); err != nil {
			return nil, err
		}

		if len(keys) < 50 {
			keys = append(keys, key.(string))
		}
	}

	if _, err := decoder.Token(); err != nil {
		return nil, err
	}

	return keys, trailing(decoder)
}

func trailing(decoder *json.Decoder) error {
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("unexpected content after the JSON value")
	}

	return nil
}

func parseCSV(body string, separator rune, most int) ([][]any, error) {
	reader := csv.NewReader(bytes.NewReader([]byte(body)))
	reader.Comma = separator
	reader.FieldsPerRecord = -1
	reader.ReuseRecord = false

	rows := [][]any{}

	for most < 0 || len(rows) < most {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}

		if err != nil {
			return nil, err
		}

		row := make([]any, len(record))
		for at, cell := range record {
			if cell == "" {
				row[at] = nil
			} else {
				row[at] = cell
			}
		}

		rows = append(rows, row)
	}

	return rows, nil
}
