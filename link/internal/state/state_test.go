package state

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	masks "github.com/masksrb/masks/go"
)

func TestConfigRefusesPlainHTTPAwayFromLoopback(t *testing.T) {
	cases := map[string]bool{
		`{"xixo":"https://xixo.example/","issuer":"https://id.example","folders":["/srv"]}`: true,
		`{"xixo":"http://xixo.localhost:8180","issuer":"http://masks.localhost:12345"}`:     true,
		`{"xixo":"http://100.64.0.2","issuer":"https://id.example"}`:                        false,
		`{"xixo":"http://127.0.0.1:8180","issuer":"http://[::1]:12345"}`:                    true,
		`{"xixo":"http://localhost.example","issuer":"https://id.example"}`:                 false,
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

	if _, _, err := held.Keys(); !errors.Is(err, ErrNoKeys) {
		t.Fatalf("running without keys gave %v", err)
	}

	key, dpop, err := held.MakeKeys()
	if err != nil {
		t.Fatal(err)
	}

	again, dpopAgain, err := held.MakeKeys()
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

func TestNestedFoldersAreRefused(t *testing.T) {
	cases := map[string]bool{
		`["/srv/media","/srv/media2"]`:                             true,
		`["/srv/media","/srv/media"]`:                              true,
		`["/srv",{"path":"/srv/media","writable":true}]`:           false,
		`[{"path":"/data","writable":true},"/data/files/private"]`: false,
		`["/","/srv"]`: false,
	}

	for folders, fine := range cases {
		path := filepath.Join(t.TempDir(), "config.json")
		os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example","folders":`+folders+`}`), 0o600)

		_, err := LoadConfig(path)
		if (err == nil) != fine {
			t.Errorf("%s gave %v", folders, err)
		}
	}
}

func TestLendAndExtractingForOthersHaveNoCeilingUntilTheConfigSetsOne(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example"}`), 0o600)

	held, err := LoadConfig(path)
	if err != nil || !held.LendCeiling() {
		t.Fatalf("%+v %v", held, err)
	}

	os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example","lend":false}`), 0o600)

	held, err = LoadConfig(path)
	if err != nil || held.LendCeiling() {
		t.Fatalf("%+v %v", held, err)
	}
}

func TestRegistrationKeepsNoRegistrationAccessToken(t *testing.T) {
	held := State{Dir: t.TempDir()}

	if err := held.Keep(&masks.Registration{ClientID: "c-1", RegistrationAccessToken: "rat", RegistrationClientURI: "https://id.example/register/c-1"}); err != nil {
		t.Fatal(err)
	}

	raw, _ := os.ReadFile(filepath.Join(held.Dir, "registration.json"))
	if strings.Contains(string(raw), "rat") || strings.Contains(string(raw), "register") {
		t.Fatalf("registration.json holds %s", raw)
	}

	if _, err := os.Stat(filepath.Join(held.Dir, "registration.json.tmp")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the temporary file stayed: %v", err)
	}
}

func TestPartsHaveNoCeilingUntilTheConfigNamesThem(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example"}`), 0o600)

	held, err := LoadConfig(path)
	if err != nil || strings.Join(held.PartCeiling(), ",") != strings.Join(Parts, ",") {
		t.Fatalf("%+v %v", held, err)
	}

	os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example","parts":[]}`), 0o600)

	held, err = LoadConfig(path)
	if err != nil || len(held.PartCeiling()) != 0 {
		t.Fatalf("%+v %v", held, err)
	}

	os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example","parts":["models"]}`), 0o600)

	held, err = LoadConfig(path)
	if err != nil || strings.Join(held.PartCeiling(), ",") != "models" {
		t.Fatalf("%+v %v", held, err)
	}

	os.WriteFile(path, []byte(`{"xixo":"https://x.example","issuer":"https://id.example","parts":["models","shell"]}`), 0o600)

	if _, err := LoadConfig(path); err == nil || !strings.Contains(err.Error(), `"shell"`) {
		t.Fatalf("an unknown part loaded: %v", err)
	}
}
