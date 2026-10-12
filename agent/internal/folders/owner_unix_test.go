//go:build unix

package folders

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestAFolderReachedThroughSomeoneElsesLinkIsRefused(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("handing a link to another account needs root")
	}

	base := t.TempDir()
	target := filepath.Join(base, "target")
	link := filepath.Join(base, "media")

	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}

	if err := os.Lchown(link, 65534, 65534); err != nil {
		t.Fatal(err)
	}

	if _, err := New([]string{link}).List(Query{Folder: link}); !errors.Is(err, ErrUntrusted) {
		t.Fatalf("a link someone else owns was followed, got %v", err)
	}
}
