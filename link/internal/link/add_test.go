package link

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

type sshCall struct {
	command string
	stdin   string
	tty     bool
}

type fakeHost struct {
	lock     sync.Mutex
	calls    []sshCall
	system   string
	linked   string
	sudoFree bool
	failing  string
}

func (h *fakeHost) ssh(_ context.Context, host, command string, stdin io.Reader, tty bool) ([]byte, error) {
	held := sshCall{command: command, tty: tty}
	if stdin != nil {
		raw, _ := io.ReadAll(stdin)
		held.stdin = string(raw)
	}

	h.lock.Lock()
	h.calls = append(h.calls, held)
	h.lock.Unlock()

	if host != "media" {
		return nil, errors.New("ssh: Could not resolve hostname " + host)
	}

	switch {
	case h.failing != "" && strings.Contains(command, h.failing):
		return nil, errors.New("exit status 1")
	case command == "uname -sm":
		return []byte(h.system + "\n"), nil
	case command == "sudo -n true 2>/dev/null":
		if h.sudoFree {
			return nil, nil
		}

		return nil, errors.New("exit status 1")
	case command == "id -un":
		return []byte("geiger\n"), nil
	case strings.HasPrefix(command, remoteBuild+" describe"):
		return []byte(`{"hostname":"media","os":"linux","arch":"amd64","folders":["/srv/media"],"writable":[],"details":{"system":"Ubuntu"}}`), nil
	case command == "xixo-link linked":
		return []byte(h.linked), nil
	case strings.HasSuffix(command, " status"):
		return []byte("media is linked up.\n"), nil
	}

	return nil, nil
}

type addFake struct {
	*httptest.Server

	lock    sync.Mutex
	build   []byte
	added   map[string]any
	auth    string
	deleted string
}

func newAddFake(t *testing.T) *addFake {
	t.Helper()
	held := &addFake{build: []byte("the linux build")}
	sum := sha256.Sum256(held.build)
	mux := http.NewServeMux()
	held.Server = httptest.NewServer(mux)
	t.Cleanup(held.Close)

	mux.HandleFunc("GET /link/builds", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode([]map[string]any{{"os": "linux", "arch": "amd64", "sha256": hex.EncodeToString(sum[:]), "version": "0.3.0"}})
	})

	mux.HandleFunc("GET /link/download/xixo-link-linux-amd64", func(w http.ResponseWriter, _ *http.Request) {
		w.Write(held.build)
	})

	mux.HandleFunc("POST /link/machines", func(w http.ResponseWriter, r *http.Request) {
		held.lock.Lock()
		defer held.lock.Unlock()

		held.auth = r.Header.Get("Authorization")
		if held.auth != "Bearer person-token" {
			w.WriteHeader(http.StatusUnauthorized)

			return
		}

		held.added = map[string]any{}
		json.NewDecoder(r.Body).Decode(&held.added)
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(map[string]any{
			"device_code": "device-9", "enrollment_token": "enroll-9", "name": "media", "links_as": "media-2",
			"url": held.URL + "/settings/resources", "issuer": "https://id.example",
			"plan": []map[string]any{{"key": "catalog", "says": "Catalog media.", "on": true}, {"key": "extract", "says": "Extract no text.", "on": false}},
		})
	})

	mux.HandleFunc("DELETE /link/machines/{key}", func(w http.ResponseWriter, r *http.Request) {
		held.lock.Lock()
		defer held.lock.Unlock()

		held.auth = r.Header.Get("Authorization")
		held.deleted = r.PathValue("key")
		w.WriteHeader(http.StatusNoContent)
	})

	return held
}

func TestAddCopiesTheBuildDescribesTheMachineAddsItInstallsEnrollsAndStarts(t *testing.T) {
	xixo := newAddFake(t)
	host := &fakeHost{system: "Linux x86_64"}
	out := &bytes.Buffer{}

	err := Add(context.Background(), Adding{
		Xixo: xixo.URL + "/", Token: "person-token", Host: "media", Folders: []string{"/srv/media", "/srv/in box:rw"}, Off: []string{"extract"},
		Terminal: true, SSH: host.ssh, Client: xixo.Client(), Out: out,
	})
	if err != nil {
		t.Fatal(err)
	}

	commands := []string{}
	for _, call := range host.calls {
		commands = append(commands, call.command)
	}

	want := []string{
		"uname -sm",
		"sudo -n true 2>/dev/null",
		"mkdir -p ~/.cache/xixo-link && cat > ~/.cache/xixo-link/xixo-link.new && chmod 0755 ~/.cache/xixo-link/xixo-link.new && mv ~/.cache/xixo-link/xixo-link.new ~/.cache/xixo-link/xixo-link",
		"~/.cache/xixo-link/xixo-link describe '/srv/media' '/srv/in box:rw'",
		"id -un",
		"xixo-link linked",
		"sudo ~/.cache/xixo-link/xixo-link install --xixo '" + xixo.URL + "' --issuer 'https://id.example' --user 'geiger' --from ~/.cache/xixo-link/xixo-link '/srv/media' '/srv/in box:rw'",
		"~/.cache/xixo-link/xixo-link join",
		"sudo ~/.cache/xixo-link/xixo-link start",
		"~/.cache/xixo-link/xixo-link status",
	}

	if strings.Join(commands, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran:\n%s", strings.Join(commands, "\n"))
	}

	if host.calls[2].stdin != "the linux build" || host.calls[2].tty {
		t.Fatalf("copy %+v", host.calls[2])
	}

	if !host.calls[6].tty || !host.calls[8].tty || host.calls[7].tty {
		t.Fatalf("ttys %+v", host.calls)
	}

	joining := Joining{}
	if json.Unmarshal([]byte(host.calls[7].stdin), &joining) != nil || joining != (Joining{EnrollmentToken: "enroll-9", DeviceCode: "device-9", Name: "media"}) {
		t.Fatalf("join read %q", host.calls[7].stdin)
	}

	if _, sent := xixo.added["key"]; sent {
		t.Fatalf("a key was sent for a machine that is not linked: %v", xixo.added)
	}

	if xixo.added["hostname"] != "media" || xixo.added["name"] != "media" {
		t.Fatalf("added %v", xixo.added)
	}

	if off, _ := xixo.added["off"].([]any); len(off) != 1 || off[0] != "extract" {
		t.Fatalf("off %v", xixo.added["off"])
	}

	for _, line := range []string{"on   Catalog media.", "off  Extract no text.", "sudo there asks for your password", "media is linked up as media-2", "media is linked up."} {
		if !strings.Contains(out.String(), line) {
			t.Fatalf("printed %q, want %q", out, line)
		}
	}
}

func TestAddWithoutATerminalStopsBeforeXixoHearsOfTheMachineUnlessSudoAsksForNothing(t *testing.T) {
	xixo := newAddFake(t)
	host := &fakeHost{system: "Linux x86_64"}

	err := Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", SSH: host.ssh, Client: xixo.Client(), Out: io.Discard})
	if !errors.Is(err, ErrNoTerminal) {
		t.Fatalf("got %v", err)
	}

	if len(host.calls) != 2 || xixo.added != nil {
		t.Fatalf("ran %+v, added %v", host.calls, xixo.added)
	}

	free := &fakeHost{system: "Linux x86_64", sudoFree: true}
	out := &bytes.Buffer{}

	if err := Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", SSH: free.ssh, Client: xixo.Client(), Out: out}); err != nil {
		t.Fatal(err)
	}

	for _, call := range free.calls {
		if call.tty {
			t.Fatalf("a tty was asked for without a terminal: %+v", call)
		}
	}

	if strings.Contains(out.String(), "asks for your password") {
		t.Fatalf("printed %q", out)
	}
}

func TestAddOnALinkedMachineSendsItsKeySoItKeepsItsPlace(t *testing.T) {
	xixo := newAddFake(t)
	host := &fakeHost{system: "Linux x86_64", linked: `{"name":"media","key":"media","url":"` + xixo.URL + `/settings/resources/1"}`}
	out := &bytes.Buffer{}

	if err := Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", Terminal: true, SSH: host.ssh, Client: xixo.Client(), Out: out}); err != nil {
		t.Fatal(err)
	}

	if xixo.added["key"] != "media" || !strings.Contains(out.String(), "linked up as already") {
		t.Fatalf("added %v, printed %q", xixo.added, out)
	}

	elsewhere := &fakeHost{system: "Linux x86_64", linked: `{"name":"media","key":"media","url":"https://other.example/settings/resources/1"}`}
	if err := Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", Terminal: true, SSH: elsewhere.ssh, Client: xixo.Client(), Out: io.Discard}); err != nil {
		t.Fatal(err)
	}

	if _, sent := xixo.added["key"]; sent {
		t.Fatalf("a key linked to another xixo was sent: %v", xixo.added)
	}
}

func TestAddPutsTheMachineAwayAgainWhenItDoesNotInstall(t *testing.T) {
	xixo := newAddFake(t)
	host := &fakeHost{system: "Linux x86_64", failing: " install "}
	out := &bytes.Buffer{}

	err := Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", Terminal: true, SSH: host.ssh, Client: xixo.Client(), Out: out})
	if err == nil || !strings.Contains(err.Error(), "did not install") {
		t.Fatalf("got %v", err)
	}

	if xixo.deleted != "media-2" || !strings.Contains(out.String(), "put media-2 away again") {
		t.Fatalf("deleted %q, printed %q", xixo.deleted, out)
	}
}

func TestAddStopsWhenTheBuildDoesNotMatchOrTheSignInIsStale(t *testing.T) {
	xixo := newAddFake(t)
	host := &fakeHost{system: "Linux x86_64"}

	err := Add(context.Background(), Adding{Xixo: xixo.URL, Token: "stale", Host: "media", Terminal: true, SSH: host.ssh, Client: xixo.Client(), Out: io.Discard})
	if err == nil || !strings.Contains(err.Error(), "Run xixo-link login again") {
		t.Fatalf("got %v", err)
	}

	for _, call := range host.calls {
		if strings.Contains(call.command, "install") {
			t.Fatal("installed with a stale sign-in")
		}
	}

	xixo.build = []byte("tampered")
	err = Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", Terminal: true, SSH: host.ssh, Client: xixo.Client(), Out: io.Discard})
	if err == nil || !strings.Contains(err.Error(), "did not match the SHA-256") {
		t.Fatalf("got %v", err)
	}

	err = Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "elsewhere", SSH: host.ssh, Client: xixo.Client(), Out: io.Discard})
	if err == nil || !strings.Contains(err.Error(), "ssh could not reach elsewhere") {
		t.Fatalf("got %v", err)
	}

	host.system = "FreeBSD amd64"
	err = Add(context.Background(), Adding{Xixo: xixo.URL, Token: "person-token", Host: "media", Terminal: true, SSH: host.ssh, Client: xixo.Client(), Out: io.Discard})
	if !errors.Is(err, ErrOtherArch) {
		t.Fatalf("got %v", err)
	}
}

func TestRemoveUninstallsOverSSHAndPutsTheMachineAway(t *testing.T) {
	xixo := newAddFake(t)
	host := &fakeHost{system: "Linux x86_64", linked: `{"name":"Media","key":"media-2","url":""}`}
	out := &bytes.Buffer{}

	if err := Remove(context.Background(), Unlinking{Xixo: xixo.URL, Token: "person-token", Host: "media", SSH: host.ssh, Client: xixo.Client(), Out: out}); err != nil {
		t.Fatal(err)
	}

	commands := []string{}
	for _, call := range host.calls {
		commands = append(commands, call.command)
	}

	if strings.Join(commands, "\n") != "uname -sm\nxixo-link linked\nsudo xixo-link uninstall" || !host.calls[2].tty {
		t.Fatalf("ran %v", host.calls)
	}

	if xixo.deleted != "media-2" || xixo.auth != "Bearer person-token" {
		t.Fatalf("deleted %q with %q", xixo.deleted, xixo.auth)
	}

	host = &fakeHost{system: "Darwin arm64", linked: "not json"}
	xixo.deleted = ""

	if err := Remove(context.Background(), Unlinking{Xixo: xixo.URL, Token: "person-token", Host: "media", SSH: host.ssh, Client: xixo.Client(), Out: out}); err != nil {
		t.Fatal(err)
	}

	if host.calls[2].command != "xixo-link uninstall" || xixo.deleted != "" {
		t.Fatalf("ran %v, deleted %q", host.calls, xixo.deleted)
	}
}

func TestJoinEnrollsWithTheTokenAndBindsWithTheDeviceCode(t *testing.T) {
	xixo, masks, config, held := upFor(t)
	out := &bytes.Buffer{}

	linked, err := Join(context.Background(), config, held, Joining{EnrollmentToken: "iat-7", DeviceCode: "device-secret", Name: "media"}, out)
	if err != nil {
		t.Fatal(err)
	}

	if linked.Name != "nas" || xixo.bound != "device-secret" || masks.issued != 1 || !strings.Contains(out.String(), "Linked up as nas") {
		t.Fatalf("linked %+v, bound %q, issued %d, printed %q", linked, xixo.bound, masks.issued, out)
	}

	if _, err := ReadJoining(strings.NewReader(`{"enrollment_token":"x"}`)); err == nil {
		t.Fatal("join took a message without a device code")
	}
}
