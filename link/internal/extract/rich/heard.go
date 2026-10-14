package rich

import (
	"fmt"
	"math"
	"path/filepath"

	"github.com/xixo/xixo/link/internal/extract"
)

const Piece = 600

type Part struct {
	From    float64
	Seconds int
}

func Parts(duration float64, span int) []Part {
	if span <= 0 {
		return nil
	}

	if duration <= 0 {
		return []Part{{Seconds: span}}
	}

	if duration <= float64(span) {
		held := []Part{}

		for from := 0.0; from < duration; from += Piece {
			held = append(held, Part{From: from, Seconds: int(math.Ceil(math.Min(Piece, duration-from)))})
		}

		return held
	}

	count := int(math.Ceil(float64(span) / Piece))
	length := span / count
	held := make([]Part, 0, count)

	for index := range count {
		middle := duration * (float64(index) + 0.5) / float64(count)
		from := math.Max(0, math.Min(duration-float64(length), middle-float64(length)/2))
		held = append(held, Part{From: math.Floor(from), Seconds: length})
	}

	return held
}

func (p Part) file(work string, index int) extract.File {
	at := p.From
	name := fmt.Sprintf("heard-%d.wav", index)

	return extract.File{Role: "audio", Name: name, MIME: "audio/wav", Path: filepath.Join(work, name), At: &at}
}

func partly(out *extract.Output, parts []Part, duration float64, span int) {
	if duration <= float64(span) || len(parts) == 0 {
		return
	}

	if len(parts) == 1 {
		out.Drop("transcript", fmt.Sprintf("one part of %s, from the middle of %s, was heard", stamped(float64(parts[0].Seconds)), stamped(duration)))

		return
	}

	out.Drop("transcript", fmt.Sprintf("%d parts of %s each, spread across %s, were heard", len(parts), stamped(float64(parts[0].Seconds)), stamped(duration)))
}
