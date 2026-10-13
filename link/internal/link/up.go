package link

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"runtime"
	"strings"
	"time"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/dial"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/terminal"
)

const (
	mostLinkAnswer = 4096
	mostAsked      = 64 << 10
	mostTold       = 300
	slowedBy       = 5
	pollEvery      = 5
	mostName       = 200
)

var (
	ErrDenied  = errors.New("an administrator denied this machine in xixo. Run the command again to ask again")
	ErrExpired = errors.New("the request ran out before anyone approved it. Run the command again")

	pollUnit    = time.Second
	remindEvery = 60
	errUnknown  = errors.New("xixo knows no machine enrolled as this client")
	errAnswer   = errors.New("xixo answered with something xixo link cannot read")
)

type Linked struct {
	Name    string `json:"name"`
	URL     string `json:"url"`
	Updates bool   `json:"updates"`
}

type Asking struct {
	Hostname string        `json:"hostname"`
	OS       string        `json:"os"`
	Arch     string        `json:"arch"`
	Folders  []string      `json:"folders"`
	Writable []string      `json:"writable"`
	Details  machine.About `json:"details"`
}

var Describe = func(ctx context.Context, version string, folders []string) machine.About {
	return machine.New().About(ctx, version, folders)
}

type Started struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

type Approved struct {
	EnrollmentToken string `json:"enrollment_token"`
	Name            string `json:"name"`
}

type said struct {
	Error       string `json:"error"`
	Description string `json:"error_description"`
}

func Up(ctx context.Context, config *state.Config, held state.State, version string, out io.Writer, options ...masks.Option) error {
	style := terminal.For(out)

	if _, err := held.Registration(); err == nil {
		linked, err := Lookup(ctx, config, held, options...)

		switch {
		case err == nil:
			fmt.Fprintf(out, "   Already linked up as %s. It keeps the approval it has.\n", style.Bold(linked.Name))

			return nil
		case errors.Is(err, errUnknown), errors.Is(err, ErrRevoked), masks.HasCode(err, "invalid_client"):
			fmt.Fprintln(out, "   xixo no longer knows this machine, so it needs approval again.")
		default:
			return err
		}
	}

	hostname, _ := os.Hostname()
	hostname = strings.TrimSpace(hostname)

	asking := Asking{Hostname: hostname, OS: runtime.GOOS, Arch: runtime.GOARCH, Folders: []string{}, Writable: []string{}}

	for _, folder := range config.Folders {
		asking.Folders = append(asking.Folders, folder.Path)

		if folder.Writable {
			asking.Writable = append(asking.Writable, folder.Path)
		}
	}

	asking.Details = Describe(ctx, version, asking.Folders)

	started, err := start(ctx, config, asking)
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "   Open this link to approve this machine:\n\n     %s\n\n", style.Bold(terminal.Printable(started.VerificationURIComplete)))
	fmt.Fprintf(out, "   Check that the page shows the code %s, then choose Approve.\n", style.Bold(terminal.Printable(started.UserCode)))
	fmt.Fprintf(out, "   This command waits until you do. The request runs out in %s.\n", minutes(lasting(started)))

	approved, err := await(ctx, config, started, out)
	if err != nil {
		return err
	}

	name := hostname
	if name == "" {
		name = approved.Name
	}

	if _, err := Enroll(ctx, config, held, approved.EnrollmentToken, name, options...); err != nil {
		return err
	}

	linked, err := bind(ctx, config, held, started.DeviceCode, options...)
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "   %s Linked up as %s.\n", style.Green("Approved."), style.Bold(linked.Name))

	return nil
}

func lasting(started *Started) int {
	if started.ExpiresIn <= 0 {
		return 600
	}

	return started.ExpiresIn
}

func minutes(seconds int) string {
	held := (seconds + 59) / 60
	if held == 1 {
		return "1 minute"
	}

	return fmt.Sprintf("%d minutes", held)
}

func unreachable(err error, xixo string) error {
	if errors.Is(err, context.Canceled) {
		return err
	}

	return fmt.Errorf("xixo link could not reach xixo at %s. Check that this machine can reach it, then run the command again: %w", xixo, err)
}

func plain() *http.Client {
	held := dial.Fetcher()
	held.Timeout = dial.Answered

	return held
}

func start(ctx context.Context, config *state.Config, asking Asking) (*Started, error) {
	body, err := json.Marshal(asking)
	if err != nil {
		return nil, err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, config.Xixo+"/link/requests", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}

	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")

	response, err := plain().Do(request)
	if err != nil {
		return nil, unreachable(err, config.Xixo)
	}
	defer response.Body.Close()

	answer, _ := io.ReadAll(io.LimitReader(response.Body, mostAsked))

	if response.StatusCode != http.StatusCreated {
		return nil, failed("xixo did not take the request to link up", response, answer)
	}

	started := &Started{}
	if err := json.Unmarshal(answer, started); err != nil || started.DeviceCode == "" || started.UserCode == "" || started.VerificationURIComplete == "" {
		return nil, errors.New("xixo answered the request to link up with something xixo link cannot read")
	}

	return started, nil
}

func await(ctx context.Context, config *state.Config, started *Started, out io.Writer) (*Approved, error) {
	every := started.Interval
	if every <= 0 {
		every = pollEvery
	}

	lasts := lasting(started)
	began := time.Now()
	deadline := began.Add(time.Duration(lasts) * pollUnit)
	reminded := began

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(every) * pollUnit):
		}

		now := time.Now()
		if now.After(deadline) {
			return nil, ErrExpired
		}

		if now.Sub(reminded) >= time.Duration(remindEvery)*pollUnit {
			reminded = now
			left := int(deadline.Sub(now) / pollUnit)
			fmt.Fprintf(out, "   Still waiting for approval. The request runs out in %s.\n", minutes(left))
		}

		approved, code, err := poll(ctx, config, started.DeviceCode)

		switch {
		case err != nil:
			return nil, err
		case approved != nil:
			return approved, nil
		case code == "authorization_pending":
		case code == "slow_down":
			every += slowedBy
		case code == "access_denied":
			return nil, ErrDenied
		case code == "expired_token":
			return nil, ErrExpired
		}
	}
}

func poll(ctx context.Context, config *state.Config, device string) (*Approved, string, error) {
	body := url.Values{"device_code": {device}}.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, config.Xixo+"/link/requests/token", strings.NewReader(body))
	if err != nil {
		return nil, "", err
	}

	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Accept", "application/json")

	response, err := plain().Do(request)
	if err != nil {
		return nil, "", unreachable(err, config.Xixo)
	}
	defer response.Body.Close()

	answer, _ := io.ReadAll(io.LimitReader(response.Body, mostAsked))

	if response.StatusCode == http.StatusOK {
		approved := &Approved{}
		if err := json.Unmarshal(answer, approved); err != nil || strings.TrimSpace(approved.EnrollmentToken) == "" {
			return nil, "", errors.New("xixo approved this machine but sent nothing it can enroll with")
		}

		return approved, "", nil
	}

	held := said{}
	if response.StatusCode == http.StatusBadRequest && json.Unmarshal(answer, &held) == nil && held.Error != "" {
		switch held.Error {
		case "authorization_pending", "slow_down", "access_denied", "expired_token":
			return nil, held.Error, nil
		}
	}

	return nil, "", failed("xixo did not answer whether this machine is approved", response, answer)
}

func failed(what string, response *http.Response, answer []byte) error {
	if told := described(response, answer); told != "" {
		return fmt.Errorf("%s (%d): %s", what, response.StatusCode, told)
	}

	return fmt.Errorf("%s (%d)", what, response.StatusCode)
}

func described(response *http.Response, answer []byte) string {
	held := said{}
	if json.Unmarshal(answer, &held) == nil {
		if held.Description != "" {
			return held.Description
		}

		return held.Error
	}

	told := strings.TrimSpace(string(answer))
	if !strings.HasPrefix(response.Header.Get("Content-Type"), "text/plain") || len(told) > mostTold || strings.ContainsAny(told, "<\n") {
		return ""
	}

	return told
}

func Lookup(ctx context.Context, config *state.Config, held state.State, options ...masks.Option) (*Linked, error) {
	return signed(ctx, config, held, http.MethodGet, "", options...)
}

func bind(ctx context.Context, config *state.Config, held state.State, device string, options ...masks.Option) (*Linked, error) {
	return signed(ctx, config, held, http.MethodPost, url.Values{"device_code": {device}}.Encode(), options...)
}

func signed(ctx context.Context, config *state.Config, held state.State, method, form string, options ...masks.Option) (*Linked, error) {
	client, _, err := Client(ctx, config, held, options...)
	if err != nil {
		return nil, err
	}

	var body io.Reader
	if form != "" {
		body = strings.NewReader(form)
	}

	request, err := http.NewRequestWithContext(ctx, method, config.Xixo+"/link", body)
	if err != nil {
		return nil, err
	}

	request.Header.Set("Accept", "application/json")

	if form != "" {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}

	response, err := client.HTTPClient(Tokens(client, config), config.Xixo).Do(request)
	if held := (&masks.Error{}); errors.As(err, &held) {
		return nil, refused(err)
	}

	if err != nil {
		return nil, unreachable(err, config.Xixo)
	}
	defer response.Body.Close()

	answer, _ := io.ReadAll(io.LimitReader(response.Body, mostLinkAnswer))

	switch {
	case response.StatusCode == http.StatusOK:
		return linkedFrom(config, answer)
	case method == http.MethodGet && response.StatusCode == http.StatusNotFound:
		return nil, errUnknown
	case method == http.MethodGet:
		return nil, failed("xixo did not say whether it knows this machine", response, answer)
	}

	return nil, failed("xixo did not link this machine up", response, answer)
}

func linkedFrom(config *state.Config, answer []byte) (*Linked, error) {
	linked := &Linked{}
	if err := json.Unmarshal(answer, linked); err != nil {
		return nil, errAnswer
	}

	linked.Name = strings.TrimSpace(terminal.Printable(linked.Name))
	if linked.Name == "" || len(linked.Name) > mostName {
		return nil, errAnswer
	}

	if linked.URL != terminal.Printable(linked.URL) || !strings.HasPrefix(linked.URL, config.Xixo+"/") || strings.ContainsAny(linked.URL, " \"'<>") {
		linked.URL = ""
	}

	return linked, nil
}
