package link

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/state"
)

type xixoFake struct {
	*httptest.Server

	lock     sync.Mutex
	answers  []string
	known    bool
	asked    Asking
	started  int
	polled   int
	bound    string
	signedBy string
}

func newXixo(t *testing.T, answers ...string) *xixoFake {
	held := &xixoFake{answers: answers}
	mux := http.NewServeMux()
	held.Server = httptest.NewServer(mux)
	t.Cleanup(held.Close)

	mux.HandleFunc("GET /link", func(response http.ResponseWriter, request *http.Request) {
		held.lock.Lock()
		defer held.lock.Unlock()

		held.signedBy = request.Header.Get("Authorization")
		if !held.known {
			http.Error(response, "xixo knows no machine enrolled as this client.", http.StatusNotFound)

			return
		}

		io.WriteString(response, "Linked up as nas.\n")
	})

	mux.HandleFunc("POST /link/requests", func(response http.ResponseWriter, request *http.Request) {
		held.lock.Lock()
		defer held.lock.Unlock()

		held.started++
		json.NewDecoder(request.Body).Decode(&held.asked)
		response.WriteHeader(http.StatusCreated)
		json.NewEncoder(response).Encode(map[string]any{
			"device_code": "device-secret", "user_code": "WDJB-MJHT", "verification_uri": held.URL + "/link",
			"verification_uri_complete": held.URL + "/link/WDJB-MJHT", "expires_in": 600, "interval": 1,
		})
	})

	mux.HandleFunc("POST /link/requests/token", func(response http.ResponseWriter, request *http.Request) {
		request.ParseForm()

		held.lock.Lock()
		defer held.lock.Unlock()

		if request.PostForm.Get("device_code") != "device-secret" {
			t.Errorf("polled with %v", request.PostForm)
		}

		answer := "authorization_pending"
		if held.polled < len(held.answers) {
			answer = held.answers[held.polled]
		}

		held.polled++

		if answer == "approved" {
			json.NewEncoder(response).Encode(map[string]any{"enrollment_token": "iat-7", "name": "nas"})

			return
		}

		response.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(response).Encode(map[string]any{"error": answer, "error_description": "no"})
	})

	mux.HandleFunc("POST /link", func(response http.ResponseWriter, request *http.Request) {
		request.ParseForm()

		held.lock.Lock()
		defer held.lock.Unlock()

		held.bound = request.PostForm.Get("device_code")
		held.signedBy = request.Header.Get("Authorization")

		if request.Header.Get("DPoP") == "" {
			http.Error(response, "no proof", http.StatusUnauthorized)

			return
		}

		held.known = true
		io.WriteString(response, "Linked up as nas.\n")
	})

	return held
}

func upFor(t *testing.T, answers ...string) (*xixoFake, *issuer, *state.Config, state.State) {
	t.Helper()

	before := pollUnit
	pollUnit = time.Millisecond
	t.Cleanup(func() { pollUnit = before })

	beforeDescribe := Describe
	Describe = func(_ context.Context, version string, folders []string) machine.About {
		return machine.About{User: "media", System: "Ubuntu 24.04 LTS", CPUs: 4, Version: version, Disks: []machine.Disk{{Path: folders[0], Total: 2, Free: 1}}}
	}
	t.Cleanup(func() { Describe = beforeDescribe })

	xixo := newXixo(t, answers...)
	masks := newIssuer(t)
	masks.resource = xixo.URL + "/mcp"
	config := &state.Config{Xixo: xixo.URL, Issuer: masks.URL, Folders: []folders.Shared{{Path: "/srv/media"}, {Path: "/srv/inbox", Writable: true}}}

	return xixo, masks, config, state.State{Dir: filepath.Join(t.TempDir(), "state")}
}

func TestUpAsksXixoWaitsForApprovalEnrollsAndLinks(t *testing.T) {
	xixo, masks, config, held := upFor(t, "authorization_pending", "slow_down", "approved")
	out := &bytes.Buffer{}

	if err := Up(context.Background(), config, held, "1.2.3", out); err != nil {
		t.Fatal(err)
	}

	told := out.String()
	if !strings.Contains(told, "Open "+xixo.URL+"/link/WDJB-MJHT to approve this machine.\n") || !strings.Contains(told, "It shows the code WDJB-MJHT.\n") || !strings.HasSuffix(told, "Linked up as nas.\n") {
		t.Fatalf("printed %q", told)
	}

	if strings.Contains(told, "device-secret") || strings.Contains(told, "iat-7") {
		t.Fatalf("printed a secret: %q", told)
	}

	if xixo.asked.OS == "" || xixo.asked.Arch == "" || strings.Join(xixo.asked.Folders, ",") != "/srv/media,/srv/inbox" || strings.Join(xixo.asked.Writable, ",") != "/srv/inbox" {
		t.Fatalf("asked %+v", xixo.asked)
	}

	if xixo.asked.Details.User != "media" || xixo.asked.Details.Version != "1.2.3" || xixo.asked.Details.Disks[0].Path != "/srv/media" {
		t.Fatalf("described %+v", xixo.asked.Details)
	}

	if xixo.polled != 3 || xixo.bound != "device-secret" || xixo.signedBy != "DPoP at" {
		t.Fatalf("polled %d bound %q signed %q", xixo.polled, xixo.bound, xixo.signedBy)
	}

	if _, ok := masks.keys["client-7"]; !ok {
		t.Fatalf("masks registered %v", masks.keys)
	}

	again := &bytes.Buffer{}
	if err := Up(context.Background(), config, held, "1.2.3", again); err != nil || again.String() != "Already linked up as nas.\n" || xixo.started != 1 {
		t.Fatalf("up again printed %q, started %d, %v", again, xixo.started, err)
	}
}

func TestUpStartsAFreshRequestWhenXixoForgotTheMachine(t *testing.T) {
	xixo, _, config, held := upFor(t, "approved")

	if _, err := Enroll(context.Background(), config, held, "iat-1", "nas"); err != nil {
		t.Fatal(err)
	}

	if err := Up(context.Background(), config, held, "1.2.3", io.Discard); err != nil {
		t.Fatal(err)
	}

	if xixo.started != 1 || xixo.bound != "device-secret" {
		t.Fatalf("started %d bound %q", xixo.started, xixo.bound)
	}
}

func TestUpStopsWhenXixoDeniesOrTheRequestRunsOut(t *testing.T) {
	_, _, config, held := upFor(t, "authorization_pending", "access_denied")

	if err := Up(context.Background(), config, held, "1.2.3", io.Discard); !errors.Is(err, ErrDenied) {
		t.Fatalf("denied gave %v", err)
	}

	_, _, config, held = upFor(t, "expired_token")

	if err := Up(context.Background(), config, held, "1.2.3", io.Discard); !errors.Is(err, ErrExpired) {
		t.Fatalf("expired gave %v", err)
	}

	if _, err := held.Registration(); err == nil {
		t.Fatal("a machine that was never approved enrolled")
	}
}

func TestUpSaysWhyXixoRefusedTheRequest(t *testing.T) {
	xixo := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusTooManyRequests)
		io.WriteString(response, `{"error":"slow_down","error_description":"Too many requests from this address. Wait a minute."}`)
	}))
	t.Cleanup(xixo.Close)

	config := &state.Config{Xixo: xixo.URL, Issuer: "https://id.example"}

	err := Up(context.Background(), config, state.State{Dir: t.TempDir()}, "1.2.3", io.Discard)
	if err == nil || !strings.Contains(err.Error(), "Too many requests") {
		t.Fatalf("got %v", err)
	}
}

func TestUpStopsWhenItsContextEnds(t *testing.T) {
	_, _, config, held := upFor(t)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	if err := Up(ctx, config, held, "1.2.3", io.Discard); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("got %v", err)
	}
}
