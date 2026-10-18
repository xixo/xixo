package parts

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

var versionName = regexp.MustCompile(`^\d{1,6}\.\d{1,6}\.\d{1,6}$`)

func point(releases, pointer, name string) error {
	if !versionName.MatchString(name) {
		return fmt.Errorf("%q is not a version xixo link keeps", name)
	}

	temporary := filepath.Join(releases, pointer+".part")
	os.Remove(temporary)

	if err := os.Symlink(name, temporary); err != nil {
		return err
	}

	return os.Rename(temporary, filepath.Join(releases, pointer))
}

func pointed(releases, pointer string) string {
	name, err := os.Readlink(filepath.Join(releases, pointer))
	if err != nil || !versionName.MatchString(name) {
		return ""
	}

	return name
}

func prune(releases string, keep ...string) {
	kept := map[string]bool{pointed(releases, Current): true, pointed(releases, Good): true}
	for _, name := range keep {
		kept[name] = true
	}

	entries, err := os.ReadDir(releases)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if entry.IsDir() && versionName.MatchString(entry.Name()) && !kept[entry.Name()] {
			os.RemoveAll(filepath.Join(releases, entry.Name()))
		}
	}
}
