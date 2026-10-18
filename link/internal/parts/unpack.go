package parts

import (
	"archive/tar"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
)

var ErrEscapes = errors.New("the archive names a path outside itself")

func Unpack(archive, kind, into string) error {
	opened, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer opened.Close()

	var reader io.Reader

	switch kind {
	case ArchiveZstd:
		decoder, err := zstd.NewReader(opened)
		if err != nil {
			return err
		}
		defer decoder.Close()

		reader = decoder
	case ArchiveGzip:
		decoder, err := gzip.NewReader(opened)
		if err != nil {
			return err
		}
		defer decoder.Close()

		reader = decoder
	default:
		return fmt.Errorf("xixo link does not unpack %q", kind)
	}

	if err := os.MkdirAll(into, 0o755); err != nil {
		return err
	}

	entries := tar.NewReader(reader)

	for {
		header, err := entries.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}

		if err != nil {
			return err
		}

		if err := extract(entries, header, into); err != nil {
			return err
		}
	}
}

func extract(entries *tar.Reader, header *tar.Header, into string) error {
	name := filepath.Clean(strings.TrimPrefix(header.Name, "./"))
	if name == "." || name == "" {
		return nil
	}

	target, err := inside(into, name)
	if err != nil {
		return err
	}

	switch header.Typeflag {
	case tar.TypeDir:
		return os.MkdirAll(target, 0o755)
	case tar.TypeReg:
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}

		mode := os.FileMode(0o644)
		if header.Mode&0o111 != 0 {
			mode = 0o755
		}

		opened, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
		if err != nil {
			return err
		}

		_, err = io.Copy(opened, entries)
		if closed := opened.Close(); err == nil {
			err = closed
		}

		return err
	case tar.TypeSymlink:
		if filepath.IsAbs(header.Linkname) {
			return fmt.Errorf("%w: %s -> %s", ErrEscapes, name, header.Linkname)
		}

		if _, err := inside(into, filepath.Join(filepath.Dir(name), header.Linkname)); err != nil {
			return err
		}

		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}

		os.Remove(target)

		return os.Symlink(header.Linkname, target)
	default:
		return nil
	}
}

func inside(root, name string) (string, error) {
	if filepath.IsAbs(name) {
		return "", fmt.Errorf("%w: %s", ErrEscapes, name)
	}

	target := filepath.Join(root, name)
	if target != root && !strings.HasPrefix(target, root+string(filepath.Separator)) {
		return "", fmt.Errorf("%w: %s", ErrEscapes, name)
	}

	return target, nil
}
