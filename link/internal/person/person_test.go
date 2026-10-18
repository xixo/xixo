package person

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeXixo struct {
	*httptest.Server

	lock     sync.Mutex
	polled   int
	approved bool
	refresh  string
}

func newXixo(t *testing.T) *fakeXixo {
	t.Helper()
	held := &fakeXixo{}
	mux := http.NewServeMux()
	held.Server = httptest.NewServer(mux)
	t.Cleanup(held.Close)

	mux.HandleFunc("POST /link/cli/device", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"device_code": "device-1", "user_code": "WDJB-MJHT", "verification_uri": held.URL + "/device",
			"verification_uri_complete": held.URL + "/device?user_code=WDJB-MJHT", "expires_in": 600, "interval": 1,
		})
	})

	mux.HandleFunc("POST /link/cli/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		held.lock.Lock()
		defer held.lock.Unlock()

		if r.PostForm.Get("refresh_token") != "" {
			held.refresh = r.PostForm.Get("refresh_token")
			json.NewEncoder(w).Encode(map[string]any{"access_token": "fresh", "refresh_token": "refresh-2", "expires_in": 3600, "token_type": "Bearer"})

			return
		}

		held.polled++

		if r.PostForm.Get("device_code") != "device-1" {
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]any{"error": "invalid_grant", "error_description": "no such device code"})

			return
		}

		if !held.approved {
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]any{"error": "authorization_pending", "error_description": "waiting"})

			return
		}

		json.NewEncoder(w).Encode(map[string]any{"access_token": "person-token", "refresh_token": "refresh-1", "expires_in": 3600, "token_type": "Bearer"})
	})

	return held
}

func TestSignInShowsTheCodeWaitsForApprovalAndKeepsTheTokens(t *testing.T) {
	before := PollUnit
	PollUnit = 10 * time.Millisecond
	t.Cleanup(func() { PollUnit = before })

	xixo := newXixo(t)
	store := Store{Path: filepath.Join(t.TempDir(), "config", "logins.json")}
	out := &bytes.Buffer{}

	go func() {
		time.Sleep(50 * time.Millisecond)
		xixo.lock.Lock()
		xixo.approved = true
		xixo.lock.Unlock()
	}()

	login, err := SignIn(context.Background(), xixo.Client(), store, xixo.URL+"/", out)
	if err != nil {
		t.Fatal(err)
	}

	if login.AccessToken != "person-token" || login.RefreshToken != "refresh-1" || time.Until(login.ExpiresAt) < 50*time.Minute {
		t.Fatalf("login %+v", login)
	}

	if !strings.Contains(out.String(), "WDJB-MJHT") || !strings.Contains(out.String(), xixo.URL+"/device?user_code=WDJB-MJHT") {
		t.Fatalf("printed %q", out)
	}

	if xixo.polled < 2 {
		t.Fatalf("polled %d times", xixo.polled)
	}

	info, err := os.Stat(store.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("logins.json %v %v", info, err)
	}

	token, err := store.Token(context.Background(), xixo.Client(), xixo.URL)
	if err != nil || token != "person-token" {
		t.Fatalf("token %q %v", token, err)
	}

	only, err := store.Only()
	if err != nil || only != xixo.URL {
		t.Fatalf("only %q %v", only, err)
	}
}

func TestAnExpiredSignInIsRefreshedAndAMissingOneSaysToLogIn(t *testing.T) {
	xixo := newXixo(t)
	store := Store{Path: filepath.Join(t.TempDir(), "logins.json")}

	if _, err := store.Token(context.Background(), xixo.Client(), xixo.URL); !errors.Is(err, ErrNotSignedIn) {
		t.Fatalf("got %v", err)
	}

	store.Save(map[string]Login{xixo.URL: {AccessToken: "stale", RefreshToken: "refresh-1", ExpiresAt: time.Now().Add(-time.Minute)}})

	token, err := store.Token(context.Background(), xixo.Client(), xixo.URL)
	if err != nil || token != "fresh" || xixo.refresh != "refresh-1" {
		t.Fatalf("token %q %v, refreshed with %q", token, err, xixo.refresh)
	}

	logins, _ := store.Load()
	if logins[xixo.URL].RefreshToken != "refresh-2" || logins[xixo.URL].AccessToken != "fresh" {
		t.Fatalf("kept %+v", logins[xixo.URL])
	}

	store.Save(map[string]Login{xixo.URL: {AccessToken: "stale", ExpiresAt: time.Now().Add(-time.Minute)}, "https://other.example": {AccessToken: "x", ExpiresAt: time.Now().Add(time.Hour)}})

	if _, err := store.Token(context.Background(), xixo.Client(), xixo.URL); !errors.Is(err, ErrNotSignedIn) {
		t.Fatalf("got %v", err)
	}

	if _, err := store.Only(); !errors.Is(err, ErrNoXixo) {
		t.Fatalf("two sign-ins gave %v", err)
	}
}
