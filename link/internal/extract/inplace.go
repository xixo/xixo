package extract

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
)

var ErrNotInPlace = errors.New("this system cannot hand a shared file to a program where it lies")

var Copied = []string{"doc", "xlsx"}

type Source struct {
	Path    string
	Inherit *os.File
	Reads   []string
}

func Copies(mime, name string) bool {
	chosen := For(mime, name)

	return chosen != nil && slices.Contains(Copied, chosen.Name())
}

func InPlace(file *os.File, work, extension string) (*Source, error) {
	target, inherit, err := reach(file)
	if err != nil {
		return nil, err
	}

	path := filepath.Join(work, "source"+extension)
	if err := os.Symlink(target, path); err != nil {
		return nil, err
	}

	held := &Source{Path: path, Inherit: inherit}
	if inherit == nil {
		held.Reads = []string{target}
	}

	return held, nil
}

func Reading(run Runner, source *Source) Runner {
	held, ok := run.(Limited)
	if !ok || source == nil {
		return run
	}

	held.Inherit = source.Inherit
	held.Reads = append(slices.Clone(held.Reads), source.Reads...)

	return held
}
