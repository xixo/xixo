package plain

import (
	"errors"
	"strings"

	"github.com/xixo/xixo/link/internal/extract"
)

func init() {
	extract.Register(Text{})
	extract.Register(Data{})
	extract.Register(Calendar{})
	extract.Register(Contact{})
	extract.Register(Pkpass{})
	extract.Register(Fallback{})
}

const MostRead = 64 << 20

var ErrTooLarge = errors.New("the file is larger than xixo link reads as text")

func bytesOf(in extract.Input, out *extract.Output) ([]byte, error) {
	raw, err := extract.Head(in.Path, MostRead+1)
	if err != nil {
		return nil, err
	}

	if len(raw) > MostRead {
		out.Drop("bytes", "only the first "+extract.Delimited(MostRead)+" bytes were read")
		raw = raw[:MostRead]
	}

	return raw, nil
}

func textOf(in extract.Input, out *extract.Output) (string, error) {
	raw, err := bytesOf(in, out)
	if err != nil {
		return "", err
	}

	return extract.Readable(raw), nil
}

func unfold(body string) string {
	body = strings.ReplaceAll(body, "\r\n ", "")
	body = strings.ReplaceAll(body, "\r\n\t", "")
	body = strings.ReplaceAll(body, "\n ", "")

	return strings.ReplaceAll(body, "\n\t", "")
}

func unescape(value string) string {
	var out strings.Builder

	for at := 0; at < len(value); at++ {
		if value[at] == '\\' && at+1 < len(value) {
			switch value[at+1] {
			case 'n', 'N':
				out.WriteByte('\n')
				at++

				continue
			case ',', ';', '\\':
				out.WriteByte(value[at+1])
				at++

				continue
			}
		}

		out.WriteByte(value[at])
	}

	return out.String()
}

func lines(body string) []string {
	held := []string{}

	for _, line := range strings.Split(body, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			held = append(held, line)
		}
	}

	return held
}

func present(values ...string) []string {
	held := []string{}

	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			held = append(held, value)
		}
	}

	return held
}
