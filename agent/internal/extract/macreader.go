package extract

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"
)

const MacReaderName = "xixo-mac-reader"

var (
	OnMac      = runtime.GOOS == "darwin"
	executable = os.Executable

	ErrNoMacReader = errors.New("this Mac has no " + MacReaderName + " beside the agent or on PATH")
	ErrNoExiftool  = errors.New("reading this kind of file's metadata needs exiftool, which this Mac lacks")
)

func MacReader() string {
	if self, err := executable(); err == nil {
		if real, err := filepath.EvalSymlinks(self); err == nil {
			if beside := filepath.Join(filepath.Dir(real), MacReaderName); runnable(beside) {
				return beside
			}
		}
	}

	found, err := lookPath(MacReaderName)
	if err != nil {
		return ""
	}

	if real, err := filepath.EvalSymlinks(found); err == nil && filepath.IsAbs(real) {
		return real
	}

	return ""
}

func runnable(path string) bool {
	info, err := os.Stat(path)

	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

func MacProgram() string {
	if found := MacReader(); found != "" {
		return found
	}

	return MacReaderName
}

func Present(program string) bool {
	_, err := lookPath(program)

	return err == nil
}

func IsMacReader(program string) bool {
	return filepath.Base(program) == MacReaderName
}

func AskMac(ctx context.Context, run Runner, limit time.Duration, into any, command, input string, options ...string) error {
	program := MacReader()
	if program == "" {
		return ErrNoMacReader
	}

	if run == nil {
		return errors.New("no runner")
	}

	said, err := run.Run(ctx, limit, program, append([]string{command, input}, options...)...)
	if err != nil {
		return err
	}

	decoder := json.NewDecoder(strings.NewReader(string(said)))
	decoder.UseNumber()

	if err := decoder.Decode(into); err != nil {
		return fmt.Errorf("%s said something unreadable: %w", MacReaderName, err)
	}

	return nil
}

func readMetadata(ctx context.Context, in Input) (Metadata, error) {
	if OnMac && !Present("exiftool") {
		return MacMetadata(ctx, in)
	}

	return ReadMetadata(ctx, in.Run, in.Path)
}

func MacKind(mime string) string {
	switch {
	case mime == PDF:
		return "pdf"
	case Image(mime) || mime == Page:
		return "image"
	case Audio(mime) || Video(mime):
		return "media"
	}

	return ""
}

func MacMetadata(ctx context.Context, in Input) (Metadata, error) {
	if kind := MacKind(in.MIME); kind != "" {
		var said struct {
			Tags [][2]any `json:"tags"`
		}

		if err := AskMac(ctx, in.Run, metadataTime, &said, "metadata", in.Path, "--kind", kind); err != nil {
			return nil, err
		}

		held := Metadata{}

		for _, pair := range said.Tags {
			name, ok := pair[0].(string)
			if !ok || len(held) >= mostTags {
				continue
			}

			if shown := showing(pair[1]); shown != nil && !slices.Contains(plumbing, name) {
				held = append(held, Tag{Name: name, Value: shown})
			}
		}

		return held, nil
	}

	if format := TextutilFormat(in.MIME, in.Name); format != "" {
		said, err := in.Run.Run(ctx, metadataTime, "textutil", "-info", "-format", format, in.Path)
		if err != nil {
			return nil, err
		}

		return TextutilInfo(string(said)), nil
	}

	return nil, ErrNoExiftool
}

var textutilFormats = map[string]string{
	"application/msword": "doc",
	"application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
	"application/vnd.oasis.opendocument.text":                                 "odt",
	"application/rtf":          "rtf",
	"text/rtf":                 "rtf",
	"application/x-webarchive": "webarchive",
}

func TextutilFormat(mime, name string) string {
	if format, ok := textutilFormats[mime]; ok {
		return format
	}

	switch Extension(name) {
	case "doc", "docx", "odt", "rtf", "webarchive":
		return Extension(name)
	}

	return ""
}

var textutilFields = map[string]string{
	"Title": "Title", "Author": "Author", "Subject": "Subject", "Keywords": "Keywords", "Comment": "Comment",
	"Company": "Company", "Copyright": "Copyright", "Editor": "Editor", "Created": "CreateDate",
	"Last Modified": "ModifyDate", "Pages": "Pages",
}

func TextutilInfo(said string) Metadata {
	held := Metadata{}
	scanner := bufio.NewScanner(strings.NewReader(said))

	for scanner.Scan() {
		field, value, found := strings.Cut(strings.TrimSpace(scanner.Text()), ":")
		if !found {
			continue
		}

		name, ok := textutilFields[strings.TrimSpace(field)]
		if !ok {
			continue
		}

		value = strings.TrimSpace(value)

		if shown := showing(value); shown != nil {
			held = append(held, Tag{Name: name, Value: shown})
		}
	}

	return held
}
