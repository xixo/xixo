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
)

const (
	mostLinkAnswer = 4096
	mostAsked      = 64 << 10
	slowedBy       = 5
	pollEvery      = 5
)

var (
	ErrDenied  = errors.New("xixo denied this machine")
	ErrExpired = errors.New("the request ran out. Run the command again")

	pollUnit   = time.Second
	errUnknown = errors.New("xixo knows no machine enrolled as this client")
)

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
	if _, err := held.Registration(); err == nil {
		told, err := linkedAs(ctx, config, held, options...)

		switch {
		case err == nil:
			fmt.Fprintln(out, strings.Replace(told, "Linked up", "Already linked up", 1))

			return nil
		case errors.Is(err, errUnknown), errors.Is(err, ErrRevoked), masks.HasCode(err, "invalid_client"):
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

	fmt.Fprintf(out, "Open %s to approve this machine.\n", started.VerificationURIComplete)
	fmt.Fprintf(out, "It shows the code %s.\n", started.UserCode)

	approved, err := await(ctx, config, started)
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

	told, err := bind(ctx, config, held, started.DeviceCode, options...)
	if err != nil {
		return err
	}

	fmt.Fprintln(out, told)

	return nil
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
		return nil, err
	}
	defer response.Body.Close()

	answer, _ := io.ReadAll(io.LimitReader(response.Body, mostAsked))

	if response.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("xixo did not take the request to link up (%d): %s", response.StatusCode, described(answer))
	}

	started := &Started{}
	if err := json.Unmarshal(answer, started); err != nil || started.DeviceCode == "" || started.UserCode == "" || started.VerificationURIComplete == "" {
		return nil, errors.New("xixo answered the request to link up with something xixo link cannot read")
	}

	return started, nil
}

func await(ctx context.Context, config *state.Config, started *Started) (*Approved, error) {
	every := started.Interval
	if every <= 0 {
		every = pollEvery
	}

	lasts := started.ExpiresIn
	if lasts <= 0 {
		lasts = 600
	}

	deadline := time.Now().Add(time.Duration(lasts) * pollUnit)

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(every) * pollUnit):
		}

		if time.Now().After(deadline) {
			return nil, ErrExpired
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
		return nil, "", err
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

	return nil, "", fmt.Errorf("xixo did not answer whether this machine is approved (%d): %s", response.StatusCode, described(answer))
}

func described(answer []byte) string {
	held := said{}
	if json.Unmarshal(answer, &held) == nil && (held.Description != "" || held.Error != "") {
		if held.Description != "" {
			return held.Description
		}

		return held.Error
	}

	return strings.TrimSpace(string(answer))
}

func linkedAs(ctx context.Context, config *state.Config, held state.State, options ...masks.Option) (string, error) {
	return signed(ctx, config, held, http.MethodGet, "", options...)
}

func bind(ctx context.Context, config *state.Config, held state.State, device string, options ...masks.Option) (string, error) {
	return signed(ctx, config, held, http.MethodPost, url.Values{"device_code": {device}}.Encode(), options...)
}

func signed(ctx context.Context, config *state.Config, held state.State, method, form string, options ...masks.Option) (string, error) {
	client, _, err := Client(ctx, config, held, options...)
	if err != nil {
		return "", err
	}

	var body io.Reader
	if form != "" {
		body = strings.NewReader(form)
	}

	request, err := http.NewRequestWithContext(ctx, method, config.Xixo+"/link", body)
	if err != nil {
		return "", err
	}

	if form != "" {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}

	response, err := client.HTTPClient(Tokens(client, config), config.Xixo).Do(request)
	if held := (&masks.Error{}); errors.As(err, &held) {
		return "", refused(err)
	}

	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	answer, _ := io.ReadAll(io.LimitReader(response.Body, mostLinkAnswer))
	told := strings.TrimSpace(string(answer))

	switch {
	case response.StatusCode == http.StatusOK:
		return told, nil
	case method == http.MethodGet && response.StatusCode == http.StatusNotFound:
		return "", errUnknown
	case method == http.MethodGet:
		return "", fmt.Errorf("xixo did not say whether it knows this machine (%d): %s", response.StatusCode, told)
	}

	return "", fmt.Errorf("xixo did not link this machine up (%d): %s", response.StatusCode, told)
}
