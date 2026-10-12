package rich

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	ods          = "application/vnd.oasis.opendocument.spreadsheet"
	sampleRows   = 20
	mostColumns  = 30
	mostCell     = 200
	mostSheets   = 200
	mostRows     = 2_000_000
	mostUnpacked = 1 << 30
	mostSheetXML = 128 << 20
	convertTime  = 3 * time.Minute
)

var sheetTypes = map[string]bool{
	"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": true,
	"application/vnd.ms-excel": true,
	ods:                        true,
}

var (
	dated       = regexp.MustCompile(`\d.*[/\-.:].*\d|(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b`)
	lookSoffice = exec.LookPath
	errEnough   = errors.New("enough sheets were read")
)

type Sheets struct{}

func (Sheets) Name() string { return "xlsx" }

func (Sheets) Handles(mime, name string) bool { return sheetTypes[mime] }

func (Sheets) Needs() []string { return nil }

type SheetSection struct {
	extract.Section
	Rows int `json:"rows"`
}

type Shape struct {
	Name      string  `json:"name"`
	Rows      int     `json:"rows"`
	Columns   int     `json:"columns"`
	Headers   []any   `json:"headers"`
	Sample    [][]any `json:"sample"`
	Truncated bool    `json:"truncated"`
}

type workbook interface {
	walk(ctx context.Context, start func(name string) error, visit func(row int, cells []any)) error
	Close() error
}

type collected struct {
	out     *extract.Output
	shapes  []Shape
	tables  []*extract.Table
	outline []SheetSection
	text    strings.Builder
	written int
	sheets  int
	name    string
	current *sheet
}

func (Sheets) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{Extractor: "xlsx"}

	book, err := open(ctx, in)
	if err != nil {
		return nil, err
	}
	defer book.Close()

	held := &collected{out: out, shapes: []Shape{}, tables: []*extract.Table{}, outline: []SheetSection{}}

	err = book.walk(ctx, held.start, func(row int, cells []any) {
		held.current.add(row, cells, extract.MostText-held.written)
	})
	if err != nil && !errors.Is(err, errEnough) {
		return nil, fmt.Errorf("unreadable spreadsheet: %s", extract.Truncate(err.Error(), 200))
	}

	held.finish()

	out.Set("sheets", held.shapes)
	out.Set("tables", held.tables)
	out.Set("outline", held.outline)
	out.Set("text", out.Capped(held.text.String()))

	return out, nil
}

func (c *collected) start(name string) error {
	c.finish()

	if c.sheets == mostSheets {
		c.out.Drop("sheets", fmt.Sprintf("only the first %d sheets were read", mostSheets))

		return errEnough
	}

	c.sheets++
	c.name = name
	c.current = &sheet{tableRows: [][]any{}}

	return nil
}

func (c *collected) finish() {
	if c.current == nil {
		return
	}

	held, name := c.current, c.name
	c.current = nil

	c.shapes = append(c.shapes, held.shape(name))

	if table := held.table(name); table != nil {
		c.tables = append(c.tables, table)
	}

	if c.written >= extract.MostText {
		return
	}

	if c.written > 0 {
		c.text.WriteString("\n\n")
		c.written += 2
	}

	c.outline = append(c.outline, SheetSection{Section: extract.Section{Name: name, From: c.written}, Rows: held.lastRow})
	c.text.WriteString(name)
	c.written += length(name)

	for _, line := range held.lines {
		if c.written >= extract.MostText {
			break
		}

		c.text.WriteString("\n" + line)
		c.written += 1 + length(line)
	}
}

func open(ctx context.Context, in extract.Input) (workbook, error) {
	if in.MIME == ods || opendocument(in.Path) {
		book, err := openOds(in.Path)
		if err != nil {
			return nil, fmt.Errorf("unreadable spreadsheet: %s", extract.Truncate(err.Error(), 200))
		}

		return book, nil
	}

	options := excelize.Options{UnzipSizeLimit: mostUnpacked, UnzipXMLSizeLimit: mostSheetXML}

	book, err := excelize.OpenFile(in.Path, options)
	if err == nil {
		return excelBook{book}, nil
	}

	converted, convertErr := convert(ctx, in)
	if convertErr != nil {
		return nil, fmt.Errorf("unreadable spreadsheet: %s", extract.Truncate(errors.Join(err, convertErr).Error(), 200))
	}

	book, err = excelize.OpenFile(converted, options)
	if err != nil {
		return nil, fmt.Errorf("unreadable spreadsheet: %s", extract.Truncate(err.Error(), 200))
	}

	return excelBook{book}, nil
}

func convert(ctx context.Context, in extract.Input) (string, error) {
	if _, err := lookSoffice("soffice"); err != nil {
		return "", errors.New("reading this format needs LibreOffice Calc, and soffice is not installed")
	}

	into := filepath.Join(in.Work, "converted")
	if err := os.MkdirAll(into, 0o700); err != nil {
		return "", err
	}

	source := filepath.Join(into, "sheet"+safeExt(in.Name))
	if err := os.Symlink(in.Path, source); err != nil {
		return "", err
	}

	profile := "-env:UserInstallation=file://" + filepath.Join(in.Work, "profile")

	if _, err := in.Run.Run(ctx, convertTime, "soffice", profile, "--headless", "--norestore",
		"--convert-to", "xlsx", "--outdir", into, source); err != nil {
		return "", err
	}

	converted := filepath.Join(into, "sheet.xlsx")
	if _, err := os.Stat(converted); err != nil {
		return "", errors.New("LibreOffice did not convert the spreadsheet, which needs its Calc component")
	}

	return converted, nil
}

type excelBook struct {
	file *excelize.File
}

func (b excelBook) Close() error { return b.file.Close() }

func (b excelBook) walk(ctx context.Context, start func(string) error, visit func(int, []any)) error {
	for _, name := range b.file.GetSheetList() {
		if err := ctx.Err(); err != nil {
			return err
		}

		if err := start(name); err != nil {
			return err
		}

		if err := b.rows(name, visit); err != nil {
			return err
		}
	}

	return nil
}

func (b excelBook) rows(name string, visit func(int, []any)) error {
	formatted, err := b.file.Rows(name)
	if err != nil {
		return err
	}
	defer formatted.Close()

	raw, err := b.file.Rows(name)
	if err != nil {
		return err
	}
	defer raw.Close()

	row := 0

	for formatted.Next() && raw.Next() {
		row++
		if row > mostRows {
			return nil
		}

		shown, err := formatted.Columns()
		if err != nil {
			return err
		}

		values, err := raw.Columns(excelize.Options{RawCellValue: true})
		if err != nil {
			return err
		}

		cells := make([]any, len(shown))
		for index := range shown {
			cells[index] = cellOf(shown[index], at(values, index))
		}

		visit(row, cells)
	}

	return nil
}

type sheet struct {
	firstRow   int
	lastRow    int
	lastColumn int
	headers    []any
	tableRows  [][]any
	lines      []string
	room       int
}

func at(values []string, index int) string {
	if index < len(values) {
		return values[index]
	}

	return ""
}

func (s *sheet) add(row int, cells []any, room int) {
	kept := make([]any, min(len(cells), mostColumns))
	present := 0
	width := 0

	for index, cell := range cells {
		if cell == nil {
			continue
		}

		width = index + 1
		if index < mostColumns {
			kept[index] = cell
			present++
		}
	}

	if width == 0 {
		return
	}

	if s.firstRow == 0 {
		s.firstRow = row
		s.headers = kept
		s.room = room
	}

	s.lastRow = row
	s.lastColumn = max(s.lastColumn, width)

	if row <= s.firstRow+extract.MostRows {
		for len(s.tableRows) < row-s.firstRow {
			s.tableRows = append(s.tableRows, []any{})
		}

		s.tableRows = append(s.tableRows, kept)
	}

	if present == 0 || s.room <= 0 {
		return
	}

	said := []string{}
	for _, cell := range kept {
		if cell != nil {
			said = append(said, shownCell(cell))
		}
	}

	line := strings.Join(said, " | ")
	s.lines = append(s.lines, line)
	s.room -= length(line) + 1
}

func (s *sheet) shape(name string) Shape {
	columns := min(s.lastColumn, mostColumns)
	first := max(s.firstRow, 1)

	sample := [][]any{}
	for offset := 1; offset <= sampleRows && first+offset <= s.lastRow; offset++ {
		sample = append(sample, widen(s.rowAt(first+offset), columns))
	}

	return Shape{
		Name:      name,
		Rows:      s.lastRow,
		Columns:   s.lastColumn,
		Headers:   widen(s.headers, columns),
		Sample:    sample,
		Truncated: s.lastRow > first+sampleRows,
	}
}

func (s *sheet) rowAt(row int) []any {
	index := row - s.firstRow
	if index < 0 || index >= len(s.tableRows) {
		return nil
	}

	return s.tableRows[index]
}

func widen(cells []any, columns int) []any {
	held := make([]any, columns)
	copy(held, cells[:min(len(cells), columns)])

	return held
}

func (s *sheet) table(name string) *extract.Table {
	if s.firstRow == 0 {
		return nil
	}

	columns := min(s.lastColumn, mostColumns)
	rows := make([][]any, len(s.tableRows))

	for index, cells := range s.tableRows {
		rows[index] = widen(cells, columns)
	}

	return extract.Framed(name, rows)
}

func cellOf(shown, raw string) any {
	if shown == "" && raw == "" {
		return nil
	}

	switch strings.ToUpper(shown) {
	case "TRUE":
		return true
	case "FALSE":
		return false
	}

	value, err := strconv.ParseFloat(raw, 64)
	if err != nil || !finite(value) || (shown == raw && strconv.FormatFloat(value, 'f', -1, 64) != raw) {
		return extract.Truncate(valid(shown), mostCell)
	}

	if shown != raw && dated.MatchString(shown) {
		if when, err := excelize.ExcelDateToTime(value, false); err == nil {
			if value == math.Trunc(value) {
				return when.Format("2006-01-02")
			}

			return when.Format("2006-01-02T15:04:05")
		}
	}

	return numeric(value)
}

func numeric(value float64) any {
	if value == math.Trunc(value) && math.Abs(value) < 1<<53 {
		return int64(value)
	}

	return value
}

func shownCell(cell any) string {
	switch held := cell.(type) {
	case float64:
		return strconv.FormatFloat(held, 'f', -1, 64)
	default:
		return fmt.Sprint(held)
	}
}

func init() {
	extract.Register(Sheets{})
}
