package plain

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/xixo/xixo/agent/internal/extract"
)

const mostPass = 1 << 20

var (
	fieldGroups = []string{"headerFields", "primaryFields", "secondaryFields", "auxiliaryFields", "backFields"}
	styles      = []string{"boardingPass", "coupon", "eventTicket", "generic", "storeCard"}
)

type Pkpass struct{}

func (Pkpass) Name() string                { return "pkpass" }
func (Pkpass) Needs() []string             { return nil }
func (Pkpass) Handles(mime, _ string) bool { return mime == "application/vnd.apple.pkpass" }

type Field struct {
	Label any    `json:"label"`
	Value string `json:"value"`
}

type Pass struct {
	Style          any     `json:"style"`
	Organization   any     `json:"organization"`
	Description    any     `json:"description"`
	LogoText       any     `json:"logo_text"`
	SerialNumber   any     `json:"serial_number"`
	RelevantDate   any     `json:"relevant_date"`
	ExpirationDate any     `json:"expiration_date"`
	Fields         []Field `json:"fields"`
}

func (Pkpass) Extract(_ context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{}

	body, err := passJSON(in.Path)
	if err != nil {
		out.Fail("pass", err)

		return out, nil
	}

	pass, err := parsePass(body)
	if err != nil {
		out.Fail("pass", err)

		return out, nil
	}

	out.Set("pass", pass)
	out.Set("text", out.Capped(flatten(pass)))

	return out, nil
}

func passJSON(path string) ([]byte, error) {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return nil, fmt.Errorf("unreadable pkpass: %s", extract.Truncate(err.Error(), 200))
	}
	defer archive.Close()

	for _, entry := range archive.File {
		if entry.Name != "pass.json" {
			continue
		}

		opened, err := entry.Open()
		if err != nil {
			return nil, fmt.Errorf("unreadable pkpass: %s", extract.Truncate(err.Error(), 200))
		}
		defer opened.Close()

		return io.ReadAll(io.LimitReader(opened, mostPass))
	}

	return nil, errors.New("no pass.json in the bundle")
}

func parsePass(body []byte) (*Pass, error) {
	held := map[string]any{}
	if err := json.Unmarshal([]byte(extract.Readable(body)), &held); err != nil {
		return nil, fmt.Errorf("pass.json is not json: %s", extract.Truncate(err.Error(), 200))
	}

	pass := &Pass{
		Organization:   held["organizationName"],
		Description:    held["description"],
		LogoText:       held["logoText"],
		SerialNumber:   held["serialNumber"],
		RelevantDate:   held["relevantDate"],
		ExpirationDate: held["expirationDate"],
		Fields:         []Field{},
	}

	for _, style := range styles {
		if _, ok := held[style]; ok {
			pass.Style = style
			pass.Fields = fieldsOf(held[style])

			break
		}
	}

	return pass, nil
}

func fieldsOf(body any) []Field {
	grouped, ok := body.(map[string]any)
	if !ok {
		return []Field{}
	}

	fields := []Field{}

	for _, group := range fieldGroups {
		listed, _ := grouped[group].([]any)

		for _, each := range listed {
			field, ok := each.(map[string]any)
			if !ok {
				continue
			}

			value := ""
			if field["value"] != nil {
				value = shown(field["value"])
			}

			fields = append(fields, Field{Label: field["label"], Value: value})
		}
	}

	return fields
}

func shown(value any) string {
	switch held := value.(type) {
	case string:
		return held
	case float64:
		if held == float64(int64(held)) {
			return fmt.Sprint(int64(held))
		}

		return fmt.Sprint(held)
	default:
		encoded, _ := json.Marshal(held)

		return string(encoded)
	}
}

func flatten(pass *Pass) string {
	said := []string{}

	for _, value := range []any{pass.Style, pass.Organization, pass.Description, pass.LogoText,
		pass.SerialNumber, pass.RelevantDate, pass.ExpirationDate} {
		if value != nil {
			said = append(said, shown(value))
		}
	}

	for _, field := range pass.Fields {
		parts := []string{}
		if field.Label != nil {
			parts = append(parts, shown(field.Label))
		}

		said = append(said, strings.Join(append(parts, field.Value), ": "))
	}

	return strings.Join(said, "\n")
}
