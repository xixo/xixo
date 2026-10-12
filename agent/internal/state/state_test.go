package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestConfigRefusesPlainHTTPAwayFromLoopback(t *testing.T) {
	cases := map[string]bool{
		`{"xixo":"https://xixo.example/","issuer":"https://id.example","folders":["/srv"]}`: true,
		`{"xixo":"http://xixo.localhost:8180","issuer":"http://masks.localhost:12345"}`:     true,
		`{"xixo":"http://100.64.0.2","issuer":"https://id.example"}`:                        false,
		`{"xixo":"https://xixo.example","issuer":"http://id.example"}`:                      false,
		`{"xixo":"https://xixo.example","issuer":"https://id.example","folders":["srv"]}`:   false,
		`{"xixo":"","issuer":"https://id.example"}`:                                         false,
	}

	for body, fine := range cases {
		path := filepath.Join(t.TempDir(), "config.json")
		os.WriteFile(path, []byte(body), 0o600)

		held, err := LoadConfig(path)
		if (err == nil) != fine {
			t.Errorf("%s gave %v", body, err)
		}

		if fine && held.Resource() != held.Xixo+"/mcp" {
			t.Errorf("resource %s", held.Resource())
		}
	}
}

func TestKeysAreMadeOnceAndKeptPrivate(t *testing.T) {
	held := State{Dir: filepath.Join(t.TempDir(), "state")}

	key, dpop, err := held.Keys()
	if err != nil {
		t.Fatal(err)
	}

	again, dpopAgain, err := held.Keys()
	if err != nil {
		t.Fatal(err)
	}

	if key.Thumbprint() != again.Thumbprint() || dpop.Thumbprint() != dpopAgain.Thumbprint() || key.Thumbprint() == dpop.Thumbprint() {
		t.Fatal("the keys changed or are the same key")
	}

	for name, want := range map[string]os.FileMode{"": 0o700, "key.json": 0o600, "dpop.json": 0o600} {
		info, err := os.Stat(filepath.Join(held.Dir, name))
		if err != nil || info.Mode().Perm() != want {
			t.Errorf("%s mode %v %v", name, info.Mode().Perm(), err)
		}
	}
}

func TestFoldersArePathsOrWritableObjects(t *testing.T) {
	cases := map[string]bool{
		`{"xixo":"https://x.example","issuer":"https://id.example","folders":["/srv/media",{"path":"/data/files","writable":true}]}`: true,
		`{"xixo":"https://x.example","issuer":"https://id.example","folders":[{"path":"/data/files"}]}`:                              true,
		`{"xixo":"https://x.example","issuer":"https://id.example","folders":[{"path":"/data/files","writeable":true}]}`:             false,
		`{"xixo":"https://x.example","issuer":"https://id.example","folders":[{"path":"/data/../files","writable":true}]}`:           false,
		`{"xixo":"https://x.example","issuer":"https://id.example","folders":["/srv",{"path":"/srv","writable":true}]}`:              false,
		`{"xixo":"https://x.example","issuer":"https://id.example","folders":[7]}`:                                                   false,
	}

	for body, fine := range cases {
		path := filepath.Join(t.TempDir(), "config.json")
		os.WriteFile(path, []byte(body), 0o600)

		held, err := LoadConfig(path)
		if (err == nil) != fine {
			t.Errorf("%s gave %v", body, err)
		}

		if fine && len(held.Folders) > 1 && (held.Folders[0].Writable || !held.Folders[1].Writable) {
			t.Errorf("%s read as %+v", body, held.Folders)
		}
	}
}
