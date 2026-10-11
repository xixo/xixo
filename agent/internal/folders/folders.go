package folders

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

var Skipped = []string{
	".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", ".tox", ".Trash", ".Trashes", ".Spotlight-V100",
	".fseventsd", ".DS_Store", "._*", "Thumbs.db", "desktop.ini",
}

const MostListed = 500

var (
	ErrUnshared = errors.New("that folder is not shared by this machine")
	ErrOutside  = errors.New("that path is outside the folder")
	ErrSkipped  = errors.New("that path is never shared")
	ErrNotFile  = errors.New("that path is not a regular file")
)

type Folders struct {
	held map[string]string
	name []string
}

type Entry struct {
	Path       string    `json:"path"`
	Size       int64     `json:"size"`
	ModifiedAt time.Time `json:"modified_at"`
}

type Listing struct {
	Entries []Entry `json:"entries"`
	Cursor  string  `json:"cursor,omitempty"`
}

type Query struct {
	Folder string   `json:"folder"`
	Cursor string   `json:"cursor,omitempty"`
	Prefix string   `json:"prefix,omitempty"`
	Limit  int      `json:"limit,omitempty"`
	Skip   []string `json:"skip,omitempty"`
}

func New(configured []string) *Folders {
	held := &Folders{held: map[string]string{}}

	for _, folder := range configured {
		cleaned := filepath.Clean(folder)
		if _, seen := held.held[cleaned]; seen {
			continue
		}

		held.held[cleaned] = cleaned
		held.name = append(held.name, cleaned)
	}

	slices.Sort(held.name)

	return held
}

func (f *Folders) Names() []string {
	return slices.Clone(f.name)
}

func (f *Folders) root(folder string) (*os.Root, error) {
	configured, ok := f.held[filepath.Clean(folder)]
	if !ok || folder == "" {
		return nil, ErrUnshared
	}

	real, err := filepath.EvalSymlinks(configured)
	if err != nil {
		return nil, err
	}

	return os.OpenRoot(real)
}

func (f *Folders) List(query Query) (*Listing, error) {
	root, err := f.root(query.Folder)
	if err != nil {
		return nil, err
	}
	defer root.Close()

	limit := query.Limit
	if limit <= 0 || limit > MostListed {
		limit = MostListed
	}

	walk := &walker{
		root:   root,
		skip:   append(slices.Clone(Skipped), query.Skip...),
		prefix: strings.TrimPrefix(query.Prefix, "/"),
		after:  query.Cursor,
		limit:  limit,
		listed: &Listing{Entries: []Entry{}},
	}

	if err := walk.descend("."); err != nil && !errors.Is(err, errFull) {
		return nil, err
	}

	if walk.full {
		walk.listed.Cursor = walk.listed.Entries[len(walk.listed.Entries)-1].Path
	}

	return walk.listed, nil
}

var errFull = errors.New("full")

type walker struct {
	root   *os.Root
	skip   []string
	prefix string
	after  string
	limit  int
	listed *Listing
	full   bool
}

func (w *walker) descend(dir string) error {
	opened, err := w.root.Open(dir)
	if err != nil {
		if dir == "." {
			return err
		}

		return nil
	}

	children, err := opened.ReadDir(-1)
	opened.Close()

	if err != nil && dir == "." {
		return err
	}

	slices.SortFunc(children, func(a, b fs.DirEntry) int { return strings.Compare(a.Name(), b.Name()) })

	for _, child := range children {
		if skipped(child.Name(), w.skip) {
			continue
		}

		name := child.Name()
		if dir != "." {
			name = dir + "/" + child.Name()
		}

		switch kind := child.Type(); {
		case kind&fs.ModeSymlink != 0:
			continue
		case child.IsDir():
			if !toward(name, w.prefix) || before(name, w.after) {
				continue
			}

			if err := w.descend(name); err != nil {
				return err
			}
		case kind.IsRegular():
			if !strings.HasPrefix(name, w.prefix) || (w.after != "" && compare(name, w.after) <= 0) {
				continue
			}

			info, err := child.Info()
			if err != nil {
				continue
			}

			if len(w.listed.Entries) == w.limit {
				w.full = true

				return errFull
			}

			w.listed.Entries = append(w.listed.Entries, Entry{Path: name, Size: info.Size(), ModifiedAt: info.ModTime().UTC()})
		}
	}

	return nil
}

func skipped(name string, patterns []string) bool {
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" {
			continue
		}

		if matched, _ := path.Match(pattern, name); matched {
			return true
		}
	}

	return false
}

func toward(dir, prefix string) bool {
	return prefix == "" || strings.HasPrefix(prefix, dir) || strings.HasPrefix(dir, prefix)
}

func before(dir, cursor string) bool {
	if cursor == "" {
		return false
	}

	parts := strings.Split(dir, "/")
	held := strings.Split(cursor, "/")

	if len(held) > len(parts) {
		held = held[:len(parts)]
	}

	return slices.Compare(parts, held) < 0
}

func compare(a, b string) int {
	return slices.Compare(strings.Split(a, "/"), strings.Split(b, "/"))
}

type Opened struct {
	io.ReadCloser
	Size int64
}

func (f *Folders) Open(folder, name string) (*Opened, error) {
	relative, err := confined(name)
	if err != nil {
		return nil, err
	}

	for part := range strings.SplitSeq(relative, "/") {
		if skipped(part, Skipped) {
			return nil, ErrSkipped
		}
	}

	root, err := f.root(folder)
	if err != nil {
		return nil, err
	}
	defer root.Close()

	if err := straight(root, relative); err != nil {
		return nil, err
	}

	opened, err := root.OpenFile(relative, os.O_RDONLY|noFollow, 0)
	if err != nil {
		return nil, err
	}

	info, err := opened.Stat()
	if err != nil {
		opened.Close()

		return nil, err
	}

	if !info.Mode().IsRegular() {
		opened.Close()

		return nil, ErrNotFile
	}

	return &Opened{ReadCloser: opened, Size: info.Size()}, nil
}

func confined(name string) (string, error) {
	if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "\x00") || strings.Contains(name, "\\") {
		return "", ErrOutside
	}

	cleaned := path.Clean(name)
	if cleaned != name || cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", ErrOutside
	}

	return cleaned, nil
}

func straight(root *os.Root, relative string) error {
	walked := ""

	for part := range strings.SplitSeq(relative, "/") {
		if walked == "" {
			walked = part
		} else {
			walked += "/" + part
		}

		info, err := root.Lstat(walked)
		if err != nil {
			return err
		}

		if info.Mode()&fs.ModeSymlink != 0 {
			return fmt.Errorf("%w: %s is a link", ErrOutside, walked)
		}
	}

	return nil
}
