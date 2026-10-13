package folders

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path"
	"regexp"
	"slices"
	"strings"
)

var (
	ErrChanged = errors.New("the file no longer holds the bytes xixo named, so xixo link kept it")
	ErrNoHash  = errors.New("a removal names the file's SHA-256 as 64 lowercase hex characters and its size")
	sha256Hex  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	Litter     = []string{".DS_Store", "Thumbs.db", "desktop.ini"}
)

type Removed struct {
	Path   string   `json:"path"`
	Size   int64    `json:"size"`
	Pruned []string `json:"pruned,omitempty"`
}

func (f *Folders) Remove(ctx context.Context, folder, name, sum string, size int64, prune bool) (*Removed, error) {
	if !sha256Hex.MatchString(sum) || size < 0 {
		return nil, ErrNoHash
	}

	relative, err := confined(name)
	if err != nil {
		return nil, err
	}

	for part := range strings.SplitSeq(relative, "/") {
		if skipped(part, Skipped) {
			return nil, ErrSkipped
		}
	}

	if f.Shares(folder) && !f.Writes(folder) {
		return nil, ErrReadOnly
	}

	if f.overlaps(folder) {
		return nil, ErrOverlaps
	}

	root, err := f.root(folder)
	if err != nil {
		return nil, err
	}
	defer root.Close()

	if err := straight(root, relative); err != nil {
		return nil, err
	}

	if err := matches(ctx, root, relative, sum, size); err != nil {
		return nil, err
	}

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	if err := root.Remove(relative); err != nil {
		return nil, err
	}

	removed := &Removed{Path: relative, Size: size}
	if prune {
		removed.Pruned = pruned(root, path.Dir(relative))
	}

	return removed, nil
}

func matches(ctx context.Context, root *os.Root, relative, sum string, size int64) error {
	opened, err := root.OpenFile(relative, os.O_RDONLY|noFollow|nonBlock, 0)
	if err != nil {
		return err
	}
	defer opened.Close()

	before, err := opened.Stat()
	if err != nil {
		return err
	}

	if !before.Mode().IsRegular() {
		return ErrNotFile
	}

	if err := blocking(opened); err != nil {
		return err
	}

	if before.Size() != size {
		return ErrChanged
	}

	hashed := sha256.New()

	read, err := io.Copy(hashed, Halting(ctx, opened))
	if err != nil {
		return err
	}

	if read != size || hex.EncodeToString(hashed.Sum(nil)) != sum {
		return ErrChanged
	}

	after, err := opened.Stat()
	if err != nil {
		return err
	}

	if after.Size() != before.Size() || !after.ModTime().Equal(before.ModTime()) {
		return ErrChanged
	}

	there, err := root.Lstat(relative)
	if err != nil {
		return err
	}

	if !os.SameFile(there, before) {
		return ErrChanged
	}

	return nil
}

func pruned(root *os.Root, dir string) []string {
	held := []string{}

	for ; dir != "." && dir != "/"; dir = path.Dir(dir) {
		info, err := root.Lstat(dir)
		if err != nil || !info.IsDir() {
			break
		}

		if !swept(root, dir) || root.Remove(dir) != nil {
			break
		}

		held = append(held, dir)
	}

	return held
}

func swept(root *os.Root, dir string) bool {
	opened, err := root.Open(dir)
	if err != nil {
		return false
	}

	children, err := opened.ReadDir(-1)
	opened.Close()

	if err != nil {
		return false
	}

	for _, child := range children {
		if !child.Type().IsRegular() || !slices.Contains(Litter, child.Name()) {
			return false
		}
	}

	for _, child := range children {
		if root.Remove(path.Join(dir, child.Name())) != nil {
			return false
		}
	}

	return true
}
