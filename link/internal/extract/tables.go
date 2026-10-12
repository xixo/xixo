package extract

import (
	"fmt"
	"regexp"
	"strings"
)

const (
	MostRows     = 5_000
	headerWithin = 10
)

var totalled = regexp.MustCompile(`(?i)\A\s*(sub)?totals?\b`)

type Table struct {
	Name    string   `json:"name"`
	Columns []string `json:"columns"`
	Rows    [][]any  `json:"rows"`
}

func Framed(name string, rows [][]any) *Table {
	cleaned := make([][]any, len(rows))

	for at, row := range rows {
		held := make([]any, len(row))

		for index, cell := range row {
			if text, ok := cell.(string); ok {
				text = strings.TrimSpace(text)
				if text == "" {
					held[index] = nil
				} else {
					held[index] = text
				}
			} else {
				held[index] = cell
			}
		}

		cleaned[at] = held
	}

	at := headerAt(cleaned)
	if at < 0 {
		return nil
	}

	columns := make([]string, len(cleaned[at]))

	for index, cell := range cleaned[at] {
		if cell == nil || fmt.Sprint(cell) == "" {
			columns[index] = fmt.Sprintf("Column %d", index+1)
		} else {
			columns[index] = fmt.Sprint(cell)
		}
	}

	body := [][]any{}

	for _, row := range cleaned[at+1:] {
		filled := present(row)
		if len(filled) == 0 || totalled.MatchString(fmt.Sprint(filled[0])) {
			continue
		}

		if len(row) > len(columns) {
			row = row[:len(columns)]
		}

		body = append(body, row)

		if len(body) >= MostRows {
			break
		}
	}

	return &Table{Name: name, Columns: columns, Rows: body}
}

func present(row []any) []any {
	held := []any{}

	for _, cell := range row {
		if cell != nil {
			held = append(held, cell)
		}
	}

	return held
}

func headerAt(rows [][]any) int {
	head := rows[:min(len(rows), headerWithin)]
	widest := 0

	for _, row := range head {
		widest = max(widest, len(present(row)))
	}

	if widest < 2 {
		return -1
	}

	for at, row := range head {
		if len(present(row)) == widest {
			return at
		}
	}

	return -1
}
