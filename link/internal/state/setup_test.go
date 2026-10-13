package state

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/xixo/xixo/link/internal/folders"
)

func TestSetupWritesTheConfigAndKeepsWhatItDoesNotSet(t *testing.T) {
	root := t.TempDir()
	media := filepath.Join(root, "media")
	inbox := filepath.Join(root, "inbox")
	os.Mkdir(media, 0o755)
	os.Mkdir(inbox, 0o755)
	path := filepath.Join(root, "etc", "config.json")

	held, err := Setup(path, "https://xixo.example", "https://id.example", []string{media + "/", inbox + ":rw"})
	if err != nil {
		t.Fatal(err)
	}

	if len(held.Folders) != 2 || held.Folders[0].Path != media || held.Folders[0].Writable || !held.Folders[1].Writable {
		t.Fatalf("folders %+v", held.Folders)
	}

	info, _ := os.Stat(path)
	want := os.FileMode(0o644)
	if runtime.GOOS == "darwin" {
		want = 0o600
	}

	if info.Mode().Perm() != want {
		t.Fatalf("mode %v", info.Mode().Perm())
	}

	raw, _ := os.ReadFile(path)
	os.WriteFile(path, []byte(strings.Replace(string(raw), "{", `{"lend": false, "tools": ["browse"],`, 1)), 0o600)

	held, err = Setup(path, "https://other.example", "https://id.example", nil)
	if err != nil {
		t.Fatal(err)
	}

	if held.Xixo != "https://other.example" || len(held.Folders) != 2 || held.LendCeiling() || strings.Join(held.ToolCeiling(), ",") != "browse" {
		t.Fatalf("setup again gave %+v", held)
	}
}

func TestSetupRefusesFoldersItCannotShare(t *testing.T) {
	root := t.TempDir()
	os.Mkdir(filepath.Join(root, "inner"), 0o755)
	os.WriteFile(filepath.Join(root, "file"), nil, 0o644)
	path := filepath.Join(root, "config.json")

	for _, folder := range []string{"relative", filepath.Join(root, "missing"), filepath.Join(root, "file"), root + `/it"s`, root + "/a:b"} {
		if _, err := Setup(path, "https://xixo.example", "https://id.example", []string{folder}); err == nil {
			t.Errorf("%s was shared", folder)
		}
	}

	if _, err := Setup(path, "https://xixo.example", "https://id.example", []string{root, filepath.Join(root, "inner")}); err == nil {
		t.Error("nested folders were shared")
	}

	if _, err := Setup(path, "http://xixo.example", "https://id.example", nil); err == nil {
		t.Error("a plain http xixo was written")
	}

	if _, err := os.Stat(path); err == nil {
		t.Error("a refused config was written")
	}
}

func TestUnitBindsEachFolder(t *testing.T) {
	template := "[Service]\nUser=@USER@\n@FOLDERS@\nExecStart=x\n"

	written, err := Unit(template, "jon", []folders.Shared{{Path: "/srv/media"}, {Path: "/data/My 100%"}, {Path: "/srv/inbox", Writable: true}})
	if err != nil {
		t.Fatal(err)
	}

	if written != "[Service]\nUser=jon\nBindReadOnlyPaths=\"-/srv/media\" \"-/data/My 100%%\"\nBindPaths=\"-/srv/inbox\"\nExecStart=x\n" {
		t.Fatalf("wrote %q", written)
	}

	if written, _ := Unit(template, "jon", nil); written != "[Service]\nUser=jon\nExecStart=x\n" {
		t.Fatalf("wrote %q", written)
	}

	if _, err := Unit(template, "jon; rm -rf /", nil); err == nil {
		t.Fatal("an unsafe account was written")
	}

	if _, err := Unit("User=root\n", "jon", nil); err == nil {
		t.Fatal("a template without @USER@ was used")
	}
}
