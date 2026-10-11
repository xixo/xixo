package plain

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/xixo/xixo/agent/internal/extract"
)

const MostContacts = 500

var (
	single   = []string{"fn", "title", "org", "note", "bday", "nickname", "role"}
	repeated = []string{"email", "tel", "url", "impp"}
)

type Contact struct{}

func (Contact) Name() string                { return "contact" }
func (Contact) Needs() []string             { return nil }
func (Contact) Handles(mime, _ string) bool { return mime == "text/vcard" }

type Card map[string]any

func (c Card) text(key string) string {
	held, _ := c[key].(string)

	return held
}

func (c Card) list(key string) []string {
	held, _ := c[key].([]string)

	return held
}

func (Contact) Extract(_ context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{}

	body, err := textOf(in, out)
	if err != nil {
		return nil, err
	}

	contacts := parseCards(body, out)
	written := make([]string, len(contacts))
	names := make([]string, len(contacts))

	for at, card := range contacts {
		named := card.text("fn")
		if named == "" {
			named = card.text("name")
		}

		written[at] = strings.Join(present(
			named, card.text("org"), card.text("title"),
			strings.Join(card.list("email"), " "), strings.Join(card.list("tel"), " "),
			strings.Join(card.list("adr"), " "), card.text("note"),
		), " · ")

		names[at] = "Contact"

		for _, candidate := range []string{card.text("fn"), card.text("name"), first(card.list("email"))} {
			if strings.TrimSpace(candidate) != "" {
				names[at] = candidate

				break
			}
		}
	}

	out.Set("contacts", contacts)
	out.Set("outline", extract.Units(names, written))
	out.Set("text", out.Capped(strings.Join(written, "\n")))

	return out, nil
}

func first(values []string) string {
	if len(values) == 0 {
		return ""
	}

	return values[0]
}

func parseCards(body string, out *extract.Output) []Card {
	contacts := []Card{}
	var current Card

	for _, line := range lines(unfold(body)) {
		switch strings.ToUpper(line) {
		case "BEGIN:VCARD":
			current = Card{}
		case "END:VCARD":
			if len(current) > 0 {
				contacts = append(contacts, current)
			}

			current = nil

			if len(contacts) >= MostContacts {
				out.Drop("contacts", fmt.Sprintf("only the first %d contacts were read", MostContacts))

				return contacts
			}
		default:
			if current != nil {
				assignCard(current, line)
			}
		}
	}

	return contacts
}

func assignCard(card Card, line string) {
	name, value, found := strings.Cut(line, ":")
	if !found || strings.TrimSpace(value) == "" {
		return
	}

	key := property(name)

	switch {
	case slices.Contains(single, key):
		if _, held := card[key]; !held {
			card[key] = extract.Truncate(unescape(value), mostCell)
		}
	case slices.Contains(repeated, key):
		card[key] = append(card.list(key), extract.Truncate(unescape(value), mostCell))
	case key == "n":
		if _, held := card["name"]; !held {
			card["name"] = structured(value)
		}
	case key == "adr":
		card["adr"] = append(card.list("adr"), structured(value))
	}
}

func property(name string) string {
	head := strings.SplitN(name, ";", 2)[0]
	parts := strings.Split(head, ".")

	return strings.ToLower(parts[len(parts)-1])
}

func structured(value string) string {
	parts := []string{}
	start := 0

	for at := 0; at < len(value); at++ {
		if value[at] == ';' && (at == 0 || value[at-1] != '\\') {
			parts = append(parts, value[start:at])
			start = at + 1
		}
	}

	parts = append(parts, value[start:])
	kept := []string{}

	for _, part := range parts {
		if part = strings.TrimSpace(unescape(part)); part != "" {
			kept = append(kept, part)
		}
	}

	return extract.Truncate(strings.Join(kept, " "), mostCell)
}
