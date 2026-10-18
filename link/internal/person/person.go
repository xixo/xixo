package person

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/xixo/xixo/link/internal/terminal"
)

const (
	mostAnswer = 64 << 10
	soon       = time.Minute
)

var (
	ErrNotSignedIn = errors.New("you are not signed in to this xixo: run xixo-link login first")
	ErrNoXixo      = errors.New("say which xixo with --xixo, such as --xixo https://xixo.example.com")
	PollUnit       = time.Second
)

type Login struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token,omitempty"`
	ExpiresAt    time.Time `json:"expires_at"`
	Subject      string    `json:"subject,omitempty"`
}

type Store struct {
	Path string
}

func DefaultPath() string {
	if held := os.Getenv("XDG_CONFIG_HOME"); held != "" {
		return filepath.Join(held, "xixo-link", "logins.json")
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join("xixo-link", "logins.json")
	}

	return filepath.Join(home, ".config", "xixo-link", "logins.json")
}

func (s Store) Load() (map[string]Login, error) {
	raw, err := os.ReadFile(s.Path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]Login{}, nil
	}

	if err != nil {
		return nil, err
	}

	held := map[string]Login{}

	return held, json.Unmarshal(raw, &held)
}

func (s Store) Save(logins map[string]Login) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}

	raw, err := json.MarshalIndent(logins, "", "  ")
	if err != nil {
		return err
	}

	temporary := s.Path + ".tmp"
	if err := os.WriteFile(temporary, raw, 0o600); err != nil {
		return err
	}

	return os.Rename(temporary, s.Path)
}

func (s Store) Only() (string, error) {
	logins, err := s.Load()
	if err != nil {
		return "", err
	}

	if len(logins) != 1 {
		return "", ErrNoXixo
	}

	for xixo := range logins {
		return xixo, nil
	}

	return "", ErrNoXixo
}

type device struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

type tokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	Error        string `json:"error"`
	Description  string `json:"error_description"`
}

func SignIn(ctx context.Context, client *http.Client, store Store, xixo string, out io.Writer) (Login, error) {
	xixo = strings.TrimSuffix(xixo, "/")
	style := terminal.For(out)

	started := device{}
	if err := post(ctx, client, xixo+"/link/cli/device", url.Values{}, &started); err != nil {
		return Login{}, err
	}

	fmt.Fprintf(out, "Open this link to sign in to %s:\n\n  %s\n\n", terminal.Printable(xixo), style.Bold(terminal.Printable(started.VerificationURIComplete)))
	fmt.Fprintf(out, "Check that the page shows the code %s, then approve.\n", style.Bold(terminal.Printable(started.UserCode)))

	interval := time.Duration(max(started.Interval, 1)) * PollUnit
	deadline := time.Now().Add(time.Duration(max(started.ExpiresIn, 60)) * time.Second)

	for {
		select {
		case <-ctx.Done():
			return Login{}, ctx.Err()
		case <-time.After(interval):
		}

		if time.Now().After(deadline) {
			return Login{}, errors.New("the code ran out before anyone approved it. Run xixo-link login again")
		}

		answered := tokens{}
		err := post(ctx, client, xixo+"/link/cli/token", url.Values{"device_code": {started.DeviceCode}}, &answered)

		switch {
		case err == nil && answered.AccessToken != "":
		case answered.Error == "authorization_pending":
			continue
		case answered.Error == "slow_down":
			interval += PollUnit

			continue
		case err != nil:
			return Login{}, err
		default:
			return Login{}, errors.New("xixo answered without a token")
		}

		login := Login{AccessToken: answered.AccessToken, RefreshToken: answered.RefreshToken, ExpiresAt: expiry(answered.ExpiresIn)}

		logins, err := store.Load()
		if err != nil {
			return Login{}, err
		}

		logins[xixo] = login

		return login, store.Save(logins)
	}
}

func (s Store) Token(ctx context.Context, client *http.Client, xixo string) (string, error) {
	xixo = strings.TrimSuffix(xixo, "/")

	logins, err := s.Load()
	if err != nil {
		return "", err
	}

	held, ok := logins[xixo]
	if !ok {
		return "", ErrNotSignedIn
	}

	if time.Until(held.ExpiresAt) > soon {
		return held.AccessToken, nil
	}

	if held.RefreshToken == "" {
		return "", fmt.Errorf("%w: the sign-in expired", ErrNotSignedIn)
	}

	answered := tokens{}
	if err := post(ctx, client, xixo+"/link/cli/token", url.Values{"refresh_token": {held.RefreshToken}}, &answered); err != nil {
		return "", fmt.Errorf("%w: %v", ErrNotSignedIn, err)
	}

	held.AccessToken = answered.AccessToken
	held.ExpiresAt = expiry(answered.ExpiresIn)

	if answered.RefreshToken != "" {
		held.RefreshToken = answered.RefreshToken
	}

	logins[xixo] = held

	return held.AccessToken, s.Save(logins)
}

func expiry(seconds int) time.Time {
	if seconds <= 0 {
		seconds = 3600
	}

	return time.Now().Add(time.Duration(seconds) * time.Second)
}

func post(ctx context.Context, client *http.Client, address string, form url.Values, into any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, address, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}

	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Accept", "application/json")

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("xixo could not be reached at %s: %w", address, err)
	}
	defer response.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(response.Body, mostAnswer))
	if err := json.Unmarshal(raw, into); err != nil {
		return fmt.Errorf("xixo answered %s with something that is not JSON", response.Status)
	}

	if response.StatusCode >= 400 {
		told := tokens{}
		json.Unmarshal(raw, &told)

		if told.Error == "authorization_pending" || told.Error == "slow_down" {
			return nil
		}

		if told.Description != "" {
			return fmt.Errorf("xixo answered %s: %s", response.Status, told.Description)
		}

		return fmt.Errorf("xixo answered %s", response.Status)
	}

	return nil
}
