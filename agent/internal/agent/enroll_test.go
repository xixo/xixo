package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/xixo/xixo/agent/internal/state"
)

type issuer struct {
	*httptest.Server

	lock    sync.Mutex
	keys    map[string]jose.JSONWebKeySet
	deleted []string
	asked   []string
	issued  int
}

func newIssuer(t *testing.T) *issuer {
	held := &issuer{keys: map[string]jose.JSONWebKeySet{}}
	mux := http.NewServeMux()
	held.Server = httptest.NewServer(mux)
	t.Cleanup(held.Close)

	mux.HandleFunc("GET /.well-known/openid-configuration", func(response http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(response).Encode(map[string]any{
			"issuer":                held.URL,
			"token_endpoint":        held.URL + "/token",
			"registration_endpoint": held.URL + "/register",
		})
	})

	mux.HandleFunc("POST /register", func(response http.ResponseWriter, request *http.Request) {
		token := strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")
		if !strings.HasPrefix(token, "iat-") {
			http.Error(response, `{"error":"invalid_token"}`, http.StatusUnauthorized)

			return
		}

		body := struct {
			Name string             `json:"client_name"`
			JWKS jose.JSONWebKeySet `json:"jwks"`
		}{}

		if err := json.NewDecoder(request.Body).Decode(&body); err != nil || len(body.JWKS.Keys) != 1 || !body.JWKS.Keys[0].IsPublic() {
			http.Error(response, `{"error":"invalid_client_metadata"}`, http.StatusBadRequest)

			return
		}

		id := "client-" + strings.TrimPrefix(token, "iat-")

		held.lock.Lock()
		held.keys[id] = body.JWKS
		held.asked = append(held.asked, body.Name)
		held.lock.Unlock()

		response.WriteHeader(http.StatusCreated)
		json.NewEncoder(response).Encode(map[string]any{
			"client_id":                  id,
			"client_name":                body.Name,
			"token_endpoint_auth_method": "private_key_jwt",
			"grant_types":                []string{"client_credentials"},
			"dpop_bound_access_tokens":   true,
			"registration_access_token":  "rat-" + id,
			"registration_client_uri":    held.URL + "/register/" + id,
		})
	})

	mux.HandleFunc("DELETE /register/{id}", func(response http.ResponseWriter, request *http.Request) {
		id := request.PathValue("id")
		if request.Header.Get("Authorization") != "Bearer rat-"+id {
			http.Error(response, `{"error":"invalid_token"}`, http.StatusUnauthorized)

			return
		}

		held.lock.Lock()
		held.deleted = append(held.deleted, id)
		held.lock.Unlock()

		response.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /token", func(response http.ResponseWriter, request *http.Request) {
		request.ParseForm()

		refuse := func(why string) {
			t.Errorf("token request refused: %s", why)
			http.Error(response, `{"error":"invalid_client"}`, http.StatusUnauthorized)
		}

		id := request.PostForm.Get("client_id")

		held.lock.Lock()
		keys, known := held.keys[id]
		held.lock.Unlock()

		switch {
		case !known:
			refuse("unknown client")

			return
		case request.PostForm.Get("grant_type") != "client_credentials":
			refuse("grant")

			return
		case request.PostForm.Get("scope") != "xixo:agent" || request.PostForm.Get("resource") != "https://xixo.example/mcp":
			refuse("scope or resource")

			return
		case request.Header.Get("DPoP") == "":
			refuse("no proof")

			return
		}

		assertion, err := jwt.ParseSigned(request.PostForm.Get("client_assertion"), []jose.SignatureAlgorithm{jose.ES256})
		if err != nil {
			refuse(err.Error())

			return
		}

		claims := jwt.Claims{}
		if err := assertion.Claims(keys.Keys[0].Key, &claims); err != nil || claims.Subject != id || !claims.Audience.Contains(held.URL) {
			refuse("assertion")

			return
		}

		held.lock.Lock()
		held.issued++
		held.lock.Unlock()

		json.NewEncoder(response).Encode(map[string]any{"access_token": "at", "token_type": "DPoP", "expires_in": 300})
	})

	return held
}

func TestEnrollRegistersThisMachinesKey(t *testing.T) {
	masks := newIssuer(t)
	config := &state.Config{Xixo: "https://xixo.example", Issuer: masks.URL}
	held := state.State{Dir: filepath.Join(t.TempDir(), "state")}
	ctx := context.Background()

	first, err := Enroll(ctx, config, held, " iat-1\n", "nas")
	if err != nil {
		t.Fatal(err)
	}

	if first.ClientID != "client-1" || masks.asked[0] != "nas" {
		t.Fatalf("registered %+v asked %v", first, masks.asked)
	}

	key, _, _ := held.Keys()
	if masks.keys["client-1"].Keys[0].KeyID != key.Thumbprint() {
		t.Fatal("masks holds another key")
	}

	info, err := os.Stat(filepath.Join(held.Dir, "registration.json"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("registration.json %v %v", info, err)
	}

	second, err := Enroll(ctx, config, held, "iat-2", "nas")
	if err != nil {
		t.Fatal(err)
	}

	if second.ClientID != "client-2" || len(masks.deleted) != 1 || masks.deleted[0] != "client-1" {
		t.Fatalf("re-enrolling left %v deleted", masks.deleted)
	}

	if masks.keys["client-2"].Keys[0].KeyID != key.Thumbprint() {
		t.Fatal("re-enrolling made a new key")
	}

	client, dpop, err := Client(ctx, config, held)
	if err != nil {
		t.Fatal(err)
	}

	if dpop.Thumbprint() == key.Thumbprint() {
		t.Fatal("the proof key is the assertion key")
	}

	token, err := Tokens(client, config).Token(ctx)
	if err != nil || token.AccessToken != "at" || masks.issued != 1 {
		t.Fatalf("token %+v %v", token, err)
	}
}

func TestEnrollRefusesWithoutAToken(t *testing.T) {
	masks := newIssuer(t)
	config := &state.Config{Xixo: "https://xixo.example", Issuer: masks.URL}
	held := state.State{Dir: t.TempDir()}

	if _, err := Enroll(context.Background(), config, held, "  ", "nas"); err == nil {
		t.Fatal("an empty token enrolled")
	}

	if _, err := Enroll(context.Background(), config, held, "wrong", "nas"); err == nil {
		t.Fatal("a bad token enrolled")
	}

	if _, _, err := Client(context.Background(), config, held); err == nil {
		t.Fatal("an unenrolled machine has a client")
	}
}
