package folders

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

var Skipped = []string{
	".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", ".tox", ".Trash", ".Trashes", ".Spotlight-V100",
	".fseventsd", ".DS_Store", "._*", "Thumbs.db", "desktop.ini", ".xixo-*.part",
}

const MostListed = 500

var (
	ErrUnshared  = errors.New("that folder is not shared by this machine")
	ErrOutside   = errors.New("that path is outside the folder")
	ErrSkipped   = errors.New("that path is never shared")
	ErrNotFile   = errors.New("that path is not a regular file")
	ErrMoved     = errors.New("that folder now leads somewhere else, so xixo link stopped sharing it until it restarts")
	ErrUntrusted = errors.New("that folder is reached through a link someone else owns")
	ErrReadOnly  = errors.New("that folder is shared read-only")
	ErrExists    = errors.New("a file is already at that path")
	ErrShort     = errors.New("the bytes written do not match the size asked for")
	ErrOverlaps  = errors.New("that folder holds or lies inside another shared folder, so xixo link writes nothing in it")
)

type Shared struct {
	Path     string `json:"path"`
	Writable bool   `json:"writable"`
}

func (s *Shared) UnmarshalJSON(raw []byte) error {
	var path string
	if err := json.Unmarshal(raw, &path); err == nil {
		*s = Shared{Path: path}

		return nil
	}

	type plain Shared

	held := plain{}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&held); err != nil {
		return fmt.Errorf(`a folder is a path or {"path": ..., "writable": true}: %w`, err)
	}

	*s = Shared(held)

	return nil
}

func ReadOnly(paths ...string) []Shared {
	held := make([]Shared, 0, len(paths))
	for _, path := range paths {
		held = append(held, Shared{Path: path})
	}

	return held
}

type Folders struct {
	held     map[string]string
	writable map[string]bool
	name     []string
	lock     sync.Mutex
	pinned   map[string]string
}

type Entry struct {
	Path       string    `json:"path"`
	Size       int64     `json:"size"`
	ModifiedAt time.Time `json:"modified_at"`
}

type Listing struct {
	Entries      []Entry `json:"entries"`
	Cursor       string  `json:"cursor,omitempty"`
	SkippedNames int     `json:"skipped_names,omitempty"`
}

type Query struct {
	Folder string   `json:"folder"`
	Cursor string   `json:"cursor,omitempty"`
	Prefix string   `json:"prefix,omitempty"`
	Limit  int      `json:"limit,omitempty"`
	Skip   []string `json:"skip,omitempty"`
}

func New(configured []Shared) *Folders {
	held := &Folders{held: map[string]string{}, writable: map[string]bool{}, pinned: map[string]string{}}

	for _, folder := range configured {
		cleaned := filepath.Clean(folder.Path)
		if folder.Writable {
			held.writable[cleaned] = true
		}

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

func (f *Folders) Shares(folder string) bool {
	_, ok := f.held[filepath.Clean(folder)]

	return ok && folder != ""
}

func (f *Folders) Writes(folder string) bool {
	return f.Shares(folder) && f.writable[filepath.Clean(folder)]
}

func (f *Folders) Writable() []string {
	held := []string{}
	for _, name := range f.name {
		if f.writable[name] {
			held = append(held, name)
		}
	}

	return held
}

func (f *Folders) root(folder string) (*os.Root, error) {
	configured, ok := f.held[filepath.Clean(folder)]
	if !ok || folder == "" {
		return nil, ErrUnshared
	}

	real, err := f.resolve(configured)
	if err != nil {
		return nil, err
	}

	return os.OpenRoot(real)
}

func (f *Folders) Real(folder string) (string, error) {
	configured, ok := f.held[filepath.Clean(folder)]
	if !ok || folder == "" {
		return "", ErrUnshared
	}

	return f.resolve(configured)
}

func Skips(name string) bool {
	return skipped(name, Skipped) || !utf8.ValidString(name)
}

func (f *Folders) Pin() {
	for _, folder := range f.name {
		_, _ = f.resolve(folder)
	}
}

func (f *Folders) Unreadable() map[string]error {
	held := map[string]error{}

	for _, folder := range f.name {
		if err := f.readable(folder); err != nil {
			held[folder] = err
		}
	}

	return held
}

func (f *Folders) readable(folder string) error {
	root, err := f.root(folder)
	if err != nil {
		return err
	}
	defer root.Close()

	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()

	if _, err := dir.ReadDir(1); err != nil && !errors.Is(err, io.EOF) {
		return err
	}

	return nil
}

func (f *Folders) resolve(configured string) (string, error) {
	if err := trusted(configured); err != nil {
		return "", err
	}

	real, err := filepath.EvalSymlinks(configured)
	if err != nil {
		return "", err
	}

	f.lock.Lock()
	defer f.lock.Unlock()

	pinned, ok := f.pinned[configured]
	if !ok {
		f.pinned[configured] = real

		return real, nil
	}

	if pinned != real {
		return "", ErrMoved
	}

	return real, nil
}

func trusted(configured string) error {
	walked := string(filepath.Separator)

	for _, part := range strings.Split(strings.TrimPrefix(configured, walked), string(filepath.Separator)) {
		if part == "" {
			continue
		}

		walked = filepath.Join(walked, part)

		info, err := os.Lstat(walked)
		if err != nil {
			return err
		}

		if info.Mode()&fs.ModeSymlink != 0 && !ownedByUs(info) {
			return ErrUntrusted
		}
	}

	return nil
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
		if !utf8.ValidString(child.Name()) {
			w.listed.SkippedNames++

			continue
		}

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
	io.ReadSeekCloser
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

	opened, err := root.OpenFile(relative, os.O_RDONLY|noFollow|nonBlock, 0)
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

	if err := blocking(opened); err != nil {
		opened.Close()

		return nil, err
	}

	return &Opened{ReadSeekCloser: opened, Size: info.Size()}, nil
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

func (f *Folders) Write(folder, name string, body io.Reader, size int64, replace bool) (*Entry, error) {
	return f.WriteModified(folder, name, body, size, replace, time.Time{})
}

func (f *Folders) WriteModified(folder, name string, body io.Reader, size int64, replace bool, modified time.Time) (*Entry, error) {
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

	if err := made(root, path.Dir(relative)); err != nil {
		return nil, err
	}

	if err := writable(root, relative, replace); err != nil {
		return nil, err
	}

	temporary, err := spooled(root, path.Dir(relative), body, size, modified)
	if err != nil {
		return nil, err
	}
	defer root.Remove(temporary)

	if err := placed(root, temporary, relative, replace); err != nil {
		return nil, err
	}

	if held, err := root.Open(path.Dir(relative)); err == nil {
		held.Sync()
		held.Close()
	}

	info, err := root.Lstat(relative)
	if err != nil {
		return nil, err
	}

	return &Entry{Path: relative, Size: info.Size(), ModifiedAt: info.ModTime().UTC()}, nil
}

func (f *Folders) overlaps(folder string) bool {
	cleaned := filepath.Clean(folder)

	for _, other := range f.name {
		if other != cleaned && (Within(cleaned, other) || Within(other, cleaned)) {
			return true
		}
	}

	return false
}

func Within(inner, outer string) bool {
	separator := string(filepath.Separator)

	return outer == separator || strings.HasPrefix(inner, outer+separator)
}

func made(root *os.Root, dir string) error {
	if dir == "." {
		return nil
	}

	walked := ""

	for part := range strings.SplitSeq(dir, "/") {
		if walked == "" {
			walked = part
		} else {
			walked += "/" + part
		}

		info, err := root.Lstat(walked)

		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := root.Mkdir(walked, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
				return err
			}

			info, err = root.Lstat(walked)
			if err != nil {
				return err
			}
		case err != nil:
			return err
		}

		if info.Mode()&fs.ModeSymlink != 0 {
			return fmt.Errorf("%w: %s is a link", ErrOutside, walked)
		}

		if !info.IsDir() {
			return fmt.Errorf("%w: %s is not a folder", ErrOutside, walked)
		}
	}

	return nil
}

func writable(root *os.Root, relative string, replace bool) error {
	info, err := root.Lstat(relative)

	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case err != nil:
		return err
	case info.Mode()&fs.ModeSymlink != 0:
		return fmt.Errorf("%w: %s is a link", ErrOutside, relative)
	case !info.Mode().IsRegular():
		return ErrNotFile
	case !replace:
		return ErrExists
	}

	return nil
}

func spooled(root *os.Root, dir string, body io.Reader, size int64, modified time.Time) (string, error) {
	random := make([]byte, 8)
	rand.Read(random)

	temporary := path.Join(dir, ".xixo-"+hex.EncodeToString(random)+".part")

	opened, err := root.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL|noFollow, 0o644)
	if err != nil {
		return "", err
	}

	written, err := io.Copy(opened, io.LimitReader(body, size+1))
	if err == nil && written != size {
		err = ErrShort
	}

	if err == nil {
		err = opened.Sync()
	}

	if closed := opened.Close(); err == nil {
		err = closed
	}

	if err == nil && !modified.IsZero() {
		err = root.Chtimes(temporary, modified, modified)
	}

	if err != nil {
		root.Remove(temporary)

		return "", err
	}

	return temporary, nil
}

func placed(root *os.Root, temporary, relative string, replace bool) error {
	if replace {
		return root.Rename(temporary, relative)
	}

	if err := root.Link(temporary, relative); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return ErrExists
		}

		return err
	}

	return nil
}
