package link

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/xixo/xixo/link/internal/terminal"
)

const (
	remoteCache = "~/.cache/xixo-link"
	remoteBuild = remoteCache + "/xixo-link"
	mostBuild   = 256 << 20
	mostAdded   = 256 << 10
)

var (
	ErrNoHost     = errors.New("add takes the host to link up, as ssh knows it, then the folders it shares")
	ErrOtherArch  = errors.New("xixo serves no build for that machine's system and processor")
	ErrNoTerminal = errors.New("sudo there asks for a password, and there is no terminal here to type it in. Run xixo-link add from a terminal")
)

type SSH func(ctx context.Context, host string, command string, stdin io.Reader, tty bool) ([]byte, error)

type Adding struct {
	Xixo     string
	Token    string
	Host     string
	User     string
	Folders  []string
	Off      []string
	Terminal bool
	SSH      SSH
	Client   *http.Client
	Out      io.Writer
}

type build struct {
	OS      string `json:"os"`
	Arch    string `json:"arch"`
	SHA256  string `json:"sha256"`
	Version string `json:"version"`
}

type Added struct {
	DeviceCode      string           `json:"device_code"`
	EnrollmentToken string           `json:"enrollment_token"`
	Name            string           `json:"name"`
	LinksAs         string           `json:"links_as"`
	URL             string           `json:"url"`
	Issuer          string           `json:"issuer"`
	Plan            []map[string]any `json:"plan"`
}

func Add(ctx context.Context, a Adding) error {
	if a.Host == "" {
		return ErrNoHost
	}

	a.Xixo = strings.TrimSuffix(a.Xixo, "/")
	style := terminal.For(a.Out)
	step := stepper(a.Out)

	step("Asking %s what it runs.", a.Host)

	goos, goarch, err := a.system(ctx)
	if err != nil {
		return err
	}

	asksForPassword := false
	if goos == "linux" {
		if _, err := a.SSH(ctx, a.Host, "sudo -n true 2>/dev/null", nil, false); err != nil {
			if !a.Terminal {
				return fmt.Errorf("%s: %w", a.Host, ErrNoTerminal)
			}

			asksForPassword = true
		}
	}

	step("Downloading xixo link for %s on %s from %s, and copying it to %s.", goos, goarch, terminal.Printable(a.Xixo), a.Host)

	binary, err := a.download(ctx, goos, goarch)
	if err != nil {
		return err
	}

	if _, err := a.SSH(ctx, a.Host, "mkdir -p "+remoteCache+" && cat > "+remoteBuild+".new && chmod 0755 "+remoteBuild+".new && mv "+remoteBuild+".new "+remoteBuild, bytes.NewReader(binary), false); err != nil {
		return fmt.Errorf("the build could not be copied to %s: %w", a.Host, err)
	}

	step("Reading what %s is.", a.Host)

	described, err := a.describe(ctx)
	if err != nil {
		return err
	}

	user := a.User
	if user == "" {
		named, err := a.SSH(ctx, a.Host, "id -un", nil, false)
		if err != nil {
			return fmt.Errorf("%s did not say which account this is: %w", a.Host, err)
		}

		user = strings.TrimSpace(string(named))
	}

	key := a.linkedAs(ctx)
	if key == "" {
		step("Adding %s to xixo as %s.", a.Host, style.Bold(terminal.Printable(described.Hostname)))
	} else {
		step("Adding %s to xixo again as %s, which it is linked up as already.", a.Host, style.Bold(terminal.Printable(key)))
	}

	added, err := a.post(ctx, described, key)
	if err != nil {
		return err
	}

	for _, line := range added.Plan {
		mark := style.Green("on ")
		if on, _ := line["on"].(bool); !on {
			mark = "off"
		}

		fmt.Fprintf(a.Out, "   %s  %s\n", mark, terminal.Printable(fmt.Sprint(line["says"])))
	}

	install := remoteBuild + " install --xixo " + quoted(a.Xixo) + " --issuer " + quoted(added.Issuer) + " --user " + quoted(user) + " --from " + remoteBuild + quotedAll(a.Folders)
	start := remoteBuild + " start"

	switch {
	case asksForPassword:
		step("Installing xixo link on %s. sudo there asks for your password.", a.Host)
	default:
		step("Installing xixo link on %s.", a.Host)
	}

	if goos == "linux" {
		install = "sudo " + install
		start = "sudo " + start
	}

	if _, err := a.SSH(ctx, a.Host, install, nil, a.Terminal); err != nil {
		return a.undone(ctx, added, fmt.Errorf("xixo link did not install on %s: %w", a.Host, err))
	}

	step("Enrolling %s with masks, with its own key.", a.Host)

	joining, _ := json.Marshal(Joining{EnrollmentToken: added.EnrollmentToken, DeviceCode: added.DeviceCode, Name: described.Hostname})
	if out, err := a.SSH(ctx, a.Host, remoteBuild+" join", bytes.NewReader(joining), false); err != nil {
		return a.undone(ctx, added, fmt.Errorf("%s did not enroll: %w: %s", a.Host, err, strings.TrimSpace(string(out))))
	}

	step("Starting xixo link on %s.", a.Host)

	if _, err := a.SSH(ctx, a.Host, start, nil, a.Terminal); err != nil {
		return fmt.Errorf("xixo link did not start on %s: %w", a.Host, err)
	}

	status, _ := a.SSH(ctx, a.Host, remoteBuild+" status", nil, false)
	fmt.Fprintln(a.Out)
	fmt.Fprintf(a.Out, "%s %s is linked up as %s.\n\n", style.Green("Done."), a.Host, style.Bold(terminal.Printable(added.LinksAs)))
	fmt.Fprint(a.Out, terminal.Printable(string(status)))

	return nil
}

func (a Adding) undone(ctx context.Context, added *Added, failure error) error {
	if err := putAway(ctx, a.client(), a.Xixo, a.Token, added.LinksAs); err != nil {
		return fmt.Errorf("%w. xixo still lists it as %s, so remove that before trying again: %v", failure, added.LinksAs, err)
	}

	fmt.Fprintf(a.Out, "   xixo put %s away again, so the next try starts clean.\n", added.LinksAs)

	return failure
}

func putAway(ctx context.Context, client *http.Client, xixo, token, key string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, xixo+"/link/machines/"+url.PathEscape(key), nil)
	if err != nil {
		return err
	}

	request.Header.Set("Authorization", "Bearer "+token)

	response, err := client.Do(request)
	if err != nil {
		return unreachable(err, xixo)
	}
	defer response.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(response.Body, mostAdded))
	if response.StatusCode != http.StatusNoContent && response.StatusCode != http.StatusNotFound {
		return failed("xixo did not put the machine away", response, raw)
	}

	return nil
}

func (a Adding) system(ctx context.Context) (string, string, error) {
	out, err := a.SSH(ctx, a.Host, "uname -sm", nil, false)
	if err != nil {
		return "", "", fmt.Errorf("ssh could not reach %s: %w", a.Host, err)
	}

	fields := strings.Fields(string(out))
	if len(fields) != 2 {
		return "", "", fmt.Errorf("%s did not say which system it runs: %q", a.Host, strings.TrimSpace(string(out)))
	}

	goos := map[string]string{"Linux": "linux", "Darwin": "darwin"}[fields[0]]
	goarch := map[string]string{"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[fields[1]]

	if goos == "" || goarch == "" {
		return "", "", fmt.Errorf("%w: %s runs %s on %s", ErrOtherArch, a.Host, fields[0], fields[1])
	}

	return goos, goarch, nil
}

func (a Adding) download(ctx context.Context, goos, goarch string) ([]byte, error) {
	listed := []build{}
	if err := a.get(ctx, a.Xixo+"/link/builds", mostAdded, &listed); err != nil {
		return nil, err
	}

	var wanted *build
	for _, held := range listed {
		if held.OS == goos && held.Arch == goarch {
			wanted = &held

			break
		}
	}

	if wanted == nil {
		return nil, fmt.Errorf("%w: %s on %s", ErrOtherArch, goos, goarch)
	}

	raw, err := a.fetch(ctx, a.Xixo+"/link/download/xixo-link-"+goos+"-"+goarch, mostBuild)
	if err != nil {
		return nil, err
	}

	sum := sha256.Sum256(raw)
	if hex.EncodeToString(sum[:]) != wanted.SHA256 {
		return nil, errors.New("the build did not match the SHA-256 xixo states for it")
	}

	return raw, nil
}

func (a Adding) describe(ctx context.Context) (Description, error) {
	out, err := a.SSH(ctx, a.Host, remoteBuild+" describe"+quotedAll(a.Folders), nil, false)
	if err != nil {
		return Description{}, fmt.Errorf("%s could not describe itself: %w: %s", a.Host, err, strings.TrimSpace(string(out)))
	}

	held := Description{}
	if err := json.Unmarshal(out, &held); err != nil {
		return Description{}, fmt.Errorf("%s answered describe with something that is not JSON", a.Host)
	}

	if held.Hostname == "" {
		held.Hostname = a.Host
	}

	return held, nil
}

func (a Adding) linkedAs(ctx context.Context) string {
	out, err := a.SSH(ctx, a.Host, "xixo-link linked", nil, false)
	if err != nil {
		return ""
	}

	linked := Linked{}
	if json.Unmarshal(out, &linked) != nil || !machineKey.MatchString(linked.Key) || !strings.HasPrefix(linked.URL, a.Xixo+"/") {
		return ""
	}

	return linked.Key
}

func (a Adding) post(ctx context.Context, described Description, key string) (*Added, error) {
	body, _ := json.Marshal(struct {
		Description
		Name string   `json:"name"`
		Off  []string `json:"off"`
		Key  string   `json:"key,omitempty"`
	}{Description: described, Name: described.Hostname, Off: a.Off, Key: key})

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, a.Xixo+"/link/machines", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}

	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+a.Token)

	response, err := a.client().Do(request)
	if err != nil {
		return nil, unreachable(err, a.Xixo)
	}
	defer response.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(response.Body, mostAdded))
	if response.StatusCode != http.StatusCreated {
		if response.StatusCode == http.StatusUnauthorized {
			return nil, errors.New("xixo did not take your sign-in. Run xixo-link login again")
		}

		return nil, failed("xixo did not add the machine", response, raw)
	}

	held := &Added{}
	if err := json.Unmarshal(raw, held); err != nil || held.EnrollmentToken == "" || held.DeviceCode == "" {
		return nil, errAnswer
	}

	return held, nil
}

func (a Adding) client() *http.Client {
	if a.Client != nil {
		return a.Client
	}

	return plain()
}

func (a Adding) get(ctx context.Context, address string, most int64, into any) error {
	raw, err := a.fetch(ctx, address, most)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(raw, into); err != nil {
		return errAnswer
	}

	return nil
}

func (a Adding) fetch(ctx context.Context, address string, most int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}

	request.Header.Set("Accept", "application/json, application/octet-stream")

	response, err := a.client().Do(request)
	if err != nil {
		return nil, unreachable(err, a.Xixo)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered %s", address, response.Status)
	}

	return io.ReadAll(io.LimitReader(response.Body, most))
}

type Unlinking struct {
	Xixo   string
	Token  string
	Host   string
	SSH    SSH
	Client *http.Client
	Out    io.Writer
}

func Remove(ctx context.Context, r Unlinking) error {
	if r.Host == "" {
		return errors.New("remove takes the host to unlink, as ssh knows it")
	}

	r.Xixo = strings.TrimSuffix(r.Xixo, "/")
	style := terminal.For(r.Out)
	step := stepper(r.Out)
	adding := Adding{Xixo: r.Xixo, Host: r.Host, SSH: r.SSH, Client: r.Client, Out: r.Out}

	step("Asking %s what it runs, and which machine it is in xixo.", r.Host)

	goos, _, err := adding.system(ctx)
	if err != nil {
		return err
	}

	key := ""
	if out, err := r.SSH(ctx, r.Host, "xixo-link linked", nil, false); err == nil {
		linked := Linked{}
		if json.Unmarshal(out, &linked) == nil && machineKey.MatchString(linked.Key) {
			key = linked.Key
		}
	}

	uninstall := "xixo-link uninstall"
	if goos == "linux" {
		step("Removing xixo link from %s. sudo there asks for your password.", r.Host)
		uninstall = "sudo " + uninstall
	} else {
		step("Removing xixo link from %s.", r.Host)
	}

	if _, err := r.SSH(ctx, r.Host, uninstall, nil, true); err != nil {
		return fmt.Errorf("xixo link did not uninstall on %s: %w", r.Host, err)
	}

	if key == "" {
		fmt.Fprintf(r.Out, "   %s was not linked up, so there is nothing to put away in xixo.\n", r.Host)

		return nil
	}

	step("Putting %s away in xixo.", style.Bold(key))

	if err := putAway(ctx, adding.client(), r.Xixo, r.Token, key); err != nil {
		return err
	}

	fmt.Fprintf(r.Out, "\n%s %s is no longer linked up.\n", style.Green("Done."), r.Host)

	return nil
}

func stepper(out io.Writer) func(format string, args ...any) {
	style := terminal.For(out)
	steps := 0

	return func(format string, args ...any) {
		steps++
		fmt.Fprintf(out, "%s %s\n", style.Bold(fmt.Sprintf("%d.", steps)), fmt.Sprintf(format, args...))
	}
}

func quoted(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

func quotedAll(values []string) string {
	held := ""
	for _, value := range values {
		held += " " + quoted(value)
	}

	return held
}
