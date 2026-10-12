package folders

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func tree(t *testing.T) (string, string) {
	t.Helper()

	base := t.TempDir()
	shared := filepath.Join(base, "shared")
	outside := filepath.Join(base, "outside")

	files := map[string]string{
		"shared/a/b.txt":            "b",
		"shared/a.txt":              "a",
		"shared/c/d/e.txt":          "e",
		"shared/.git/config":        "secret",
		"shared/node_modules/x.js":  "x",
		"shared/._junk":             "junk",
		"shared/notes/.DS_Store":    "ds",
		"outside/secret.txt":        "secret",
		"outside/inner/private.txt": "private",
	}

	for name, body := range files {
		path := filepath.Join(base, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}

		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(shared, "link")); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(filepath.Join(outside, "inner"), filepath.Join(shared, "linkdir")); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(filepath.Join(shared, "a.txt"), filepath.Join(shared, "c", "inside")); err != nil {
		t.Fatal(err)
	}

	return shared, outside
}

func paths(listed *Listing) []string {
	held := []string{}
	for _, entry := range listed.Entries {
		held = append(held, entry.Path)
	}

	return held
}

func TestListWalksInOrderAndSkips(t *testing.T) {
	shared, _ := tree(t)
	held := New([]string{shared})

	listed, err := held.List(Query{Folder: shared})
	if err != nil {
		t.Fatal(err)
	}

	want := []string{"a/b.txt", "a.txt", "c/d/e.txt"}
	if got := paths(listed); !slices.Equal(got, want) {
		t.Fatalf("listed %v, want %v", got, want)
	}

	if listed.Cursor != "" {
		t.Fatalf("a complete listing has cursor %q", listed.Cursor)
	}

	if listed.Entries[1].Size != 1 || listed.Entries[1].ModifiedAt.IsZero() {
		t.Fatalf("an entry lacks its size or time: %+v", listed.Entries[1])
	}
}

func TestListPagesWithACursor(t *testing.T) {
	shared, _ := tree(t)
	held := New([]string{shared})

	first, err := held.List(Query{Folder: shared, Limit: 2})
	if err != nil {
		t.Fatal(err)
	}

	if got := paths(first); !slices.Equal(got, []string{"a/b.txt", "a.txt"}) || first.Cursor != "a.txt" {
		t.Fatalf("first page %v cursor %q", got, first.Cursor)
	}

	second, err := held.List(Query{Folder: shared, Limit: 2, Cursor: first.Cursor})
	if err != nil {
		t.Fatal(err)
	}

	if got := paths(second); !slices.Equal(got, []string{"c/d/e.txt"}) || second.Cursor != "" {
		t.Fatalf("second page %v cursor %q", got, second.Cursor)
	}

	resumed, err := held.List(Query{Folder: shared, Cursor: "a/b.txt"})
	if err != nil {
		t.Fatal(err)
	}

	if got := paths(resumed); !slices.Equal(got, []string{"a.txt", "c/d/e.txt"}) {
		t.Fatalf("resumed %v", got)
	}
}

func TestListTakesAPrefixAndSkips(t *testing.T) {
	shared, _ := tree(t)
	held := New([]string{shared})

	cases := []struct {
		query Query
		want  []string
	}{
		{Query{Prefix: "c/"}, []string{"c/d/e.txt"}},
		{Query{Prefix: "a"}, []string{"a/b.txt", "a.txt"}},
		{Query{Prefix: "c/d/e"}, []string{"c/d/e.txt"}},
		{Query{Skip: []string{"c", "*.md"}}, []string{"a/b.txt", "a.txt"}},
		{Query{Skip: []string{"*.txt"}}, []string{}},
	}

	for _, each := range cases {
		each.query.Folder = shared

		listed, err := held.List(each.query)
		if err != nil {
			t.Fatal(err)
		}

		if got := paths(listed); !slices.Equal(got, each.want) {
			t.Errorf("%+v listed %v, want %v", each.query, got, each.want)
		}
	}
}

func TestListRefusesAnUnsharedFolder(t *testing.T) {
	shared, outside := tree(t)
	held := New([]string{shared})

	for _, folder := range []string{outside, "", "/", filepath.Dir(shared)} {
		if _, err := held.List(Query{Folder: folder}); !errors.Is(err, ErrUnshared) {
			t.Errorf("listing %q gave %v", folder, err)
		}
	}

	if _, err := held.List(Query{Folder: shared + "/"}); err != nil {
		t.Errorf("a trailing slash names the same folder: %v", err)
	}
}

func TestAFolderMayBeALink(t *testing.T) {
	shared, _ := tree(t)
	linked := filepath.Join(t.TempDir(), "linked")

	if err := os.Symlink(shared, linked); err != nil {
		t.Fatal(err)
	}

	held := New([]string{linked})

	listed, err := held.List(Query{Folder: linked})
	if err != nil {
		t.Fatal(err)
	}

	if len(listed.Entries) != 3 {
		t.Fatalf("listed %v", paths(listed))
	}
}

func TestOpenReadsAFile(t *testing.T) {
	shared, _ := tree(t)
	held := New([]string{shared})

	opened, err := held.Open(shared, "a/b.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()

	body, _ := io.ReadAll(opened)
	if string(body) != "b" || opened.Size != 1 {
		t.Fatalf("read %q size %d", body, opened.Size)
	}
}

func TestOpenStaysInsideTheFolder(t *testing.T) {
	shared, outside := tree(t)
	held := New([]string{shared})

	cases := map[string]error{
		"../outside/secret.txt": ErrOutside,
		"/etc/passwd":           ErrOutside,
		"a/../a.txt":            ErrOutside,
		"./a.txt":               ErrOutside,
		"..":                    ErrOutside,
		"":                      ErrOutside,
		"a\\b.txt":              ErrOutside,
		"link":                  ErrOutside,
		"linkdir/private.txt":   ErrOutside,
		"c/inside":              ErrOutside,
		".git/config":           ErrSkipped,
		"node_modules/x.js":     ErrSkipped,
		"._junk":                ErrSkipped,
		"a":                     ErrNotFile,
		"missing.txt":           fs.ErrNotExist,
	}

	for name, want := range cases {
		opened, err := held.Open(shared, name)
		if opened != nil {
			opened.Close()
		}

		if !errors.Is(err, want) {
			t.Errorf("opening %q gave %v, want %v", name, err, want)
		}
	}

	if _, err := held.Open(outside, "secret.txt"); !errors.Is(err, ErrUnshared) {
		t.Errorf("opening in an unshared folder gave %v", err)
	}
}

func TestAFolderThatNowLeadsElsewhereIsRefused(t *testing.T) {
	base := t.TempDir()
	first := filepath.Join(base, "first")
	second := filepath.Join(base, "second")
	link := filepath.Join(base, "media")

	for _, dir := range []string{first, second} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	if err := os.WriteFile(filepath.Join(second, "private.txt"), []byte("private"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(first, link); err != nil {
		t.Fatal(err)
	}

	shared := New([]string{link})
	shared.Pin()

	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(second, link); err != nil {
		t.Fatal(err)
	}

	if _, err := shared.List(Query{Folder: link}); !errors.Is(err, ErrMoved) {
		t.Fatalf("a folder swapped for another was listed, got %v", err)
	}

	if _, err := shared.Open(link, "private.txt"); !errors.Is(err, ErrMoved) {
		t.Fatalf("a folder swapped for another was read, got %v", err)
	}
}

func TestANameThatIsNotUTF8IsCountedAndLeftOut(t *testing.T) {
	folder := t.TempDir()

	for _, name := range []string{"good.txt", "bad\xff.txt", "worse\xfe.txt"} {
		if err := os.WriteFile(filepath.Join(folder, name), []byte("x"), 0o644); err != nil {
			t.Skipf("this filesystem refuses the name %q: %v", name, err)
		}
	}

	listed, err := New([]string{folder}).List(Query{Folder: folder})
	if err != nil {
		t.Fatal(err)
	}

	if len(listed.Entries) != 1 || listed.Entries[0].Path != "good.txt" {
		t.Fatalf("listed %+v", listed.Entries)
	}

	if listed.SkippedNames != 2 {
		t.Fatalf("counted %d names left out", listed.SkippedNames)
	}
}
