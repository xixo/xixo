package extract

import "unicode/utf8"

const MostSections = 200

type Section struct {
	Name string `json:"name"`
	From int    `json:"from"`
}

func Units(names, lines []string) []Section {
	sections := []Section{}
	from := 0

	for at, name := range names {
		if at >= MostSections || at >= len(lines) {
			break
		}

		sections = append(sections, Section{Name: Truncate(Squish(name), 80), From: from})
		from += utf8.RuneCountInString(lines[at]) + 1
	}

	return sections
}
