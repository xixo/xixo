package plain

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	MostEvents = 200
	mostCell   = 1000
)

var (
	stamp     = regexp.MustCompile(`\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})\d{2}(Z)?)?\z`)
	eventKeys = []string{"summary", "description", "location", "dtstart", "dtend", "organizer", "status", "uid"}
)

type Calendar struct{}

func (Calendar) Name() string                { return "calendar" }
func (Calendar) Needs() []string             { return nil }
func (Calendar) Handles(mime, _ string) bool { return mime == "text/calendar" }

type Event map[string]string

func (Calendar) Extract(_ context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{}

	body, err := textOf(in, out)
	if err != nil {
		return nil, err
	}

	events := parseEvents(body, out)
	written := make([]string, len(events))
	names := make([]string, len(events))

	for at, event := range events {
		written[at] = strings.Join(present(event["summary"], ReadAs(event["dtstart"]), event["location"], event["description"]), " · ")
		names[at] = strings.Join(present(fallback(event["summary"], "Event"), ReadAs(event["dtstart"])), ", ")
	}

	out.Set("events", events)
	out.Set("outline", extract.Units(names, written))
	out.Set("text", out.Capped(strings.Join(written, "\n")))

	return out, nil
}

func parseEvents(body string, out *extract.Output) []Event {
	events := []Event{}
	var current Event

	for _, line := range lines(unfold(body)) {
		switch line {
		case "BEGIN:VEVENT":
			current = Event{}
		case "END:VEVENT":
			if current != nil {
				events = append(events, current)
			}

			current = nil

			if len(events) >= MostEvents {
				out.Drop("events", fmt.Sprintf("only the first %d events were read", MostEvents))

				return events
			}
		default:
			if current != nil {
				assignEvent(current, line)
			}
		}
	}

	return events
}

func assignEvent(event Event, line string) {
	name, value, found := strings.Cut(line, ":")
	if !found {
		return
	}

	key := strings.ToLower(strings.SplitN(name, ";", 2)[0])
	if !slices.Contains(eventKeys, key) {
		return
	}

	event[key] = extract.Truncate(unescape(value), mostCell)
}

func ReadAs(held string) string {
	parts := stamp.FindStringSubmatch(held)
	if parts == nil {
		return held
	}

	year, _ := strconv.Atoi(parts[1])
	month, _ := strconv.Atoi(parts[2])
	day, _ := strconv.Atoi(parts[3])

	date := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	if date.Year() != year || int(date.Month()) != month || date.Day() != day {
		return held
	}

	said := date.Format("Monday, January 2, 2006")
	if parts[4] == "" {
		return said
	}

	said = fmt.Sprintf("%s, %s:%s", said, parts[4], parts[5])
	if parts[6] != "" {
		said += " UTC"
	}

	return said
}

func fallback(value, otherwise string) string {
	if strings.TrimSpace(value) == "" {
		return otherwise
	}

	return value
}
