package registry

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
)

type fakeRegistry struct {
	server    *httptest.Server
	manifests map[string][]byte
	blobs     map[string][]byte
	tags      []string
	tokens    int
	lie       bool
}

func newRegistry(t *testing.T) (*fakeRegistry, *Client) {
	t.Helper()
	fake := &fakeRegistry{manifests: map[string][]byte{}, blobs: map[string][]byte{}}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.serve))
	t.Cleanup(fake.server.Close)

	return fake, &Client{HTTP: fake.server.Client(), Base: func(string) string { return fake.server.URL }}
}

func (f *fakeRegistry) serve(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/token" {
		f.tokens++
		if r.URL.Query().Get("scope") != "repository:xixo/xixo:pull" {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"token": "anonymous"})
		return
	}

	if r.Header.Get("Authorization") != "Bearer anonymous" {
		w.Header().Set("WWW-Authenticate", `Bearer realm="`+f.server.URL+`/token",service="ghcr.io",scope="repository:xixo/xixo:pull"`)
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	switch {
	case strings.HasPrefix(r.URL.Path, "/v2/xixo/xixo/manifests/"):
		held, found := f.manifests[strings.TrimPrefix(r.URL.Path, "/v2/xixo/xixo/manifests/")]
		if !found {
			http.NotFound(w, r)
			return
		}
		w.Write(held)
	case strings.HasPrefix(r.URL.Path, "/v2/xixo/xixo/blobs/"):
		held, found := f.blobs[strings.TrimPrefix(r.URL.Path, "/v2/xixo/xixo/blobs/")]
		if !found {
			http.NotFound(w, r)
			return
		}
		if f.lie {
			held = []byte("something else")
		}
		w.Write(held)
	case r.URL.Path == "/v2/xixo/xixo/tags/list":
		json.NewEncoder(w).Encode(map[string]any{"tags": f.tags})
	default:
		http.NotFound(w, r)
	}
}

func (f *fakeRegistry) manifest(held any, tags ...string) string {
	raw, _ := json.Marshal(held)
	digest := sha(raw)
	f.manifests[digest] = raw
	for _, tag := range tags {
		f.manifests[tag] = raw
	}

	return digest
}

func (f *fakeRegistry) blob(raw []byte) string {
	digest := sha(raw)
	f.blobs[digest] = raw

	return digest
}

func (f *fakeRegistry) image(t *testing.T) string {
	t.Helper()
	config := f.blob([]byte(`{"config":{"Labels":{"org.opencontainers.image.revision":"c589ffe"}}}`))
	platform := f.manifest(map[string]any{"mediaType": Manifest, "config": map[string]any{"digest": config}})
	index := f.manifest(map[string]any{"mediaType": Index, "manifests": []any{
		map[string]any{"digest": platform, "platform": map[string]string{"os": "linux", "architecture": runtime.GOARCH}},
	}}, "main")

	bundle := f.blob([]byte(`{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}`))
	attestation := f.manifest(map[string]any{"mediaType": Manifest, "layers": []any{map[string]any{"mediaType": Bundle, "digest": bundle}}})
	other := f.manifest(map[string]any{"mediaType": Manifest, "layers": []any{map[string]any{"mediaType": Bundle, "digest": bundle}}, "x": 1})
	f.manifest(map[string]any{"mediaType": Index, "manifests": []any{
		map[string]any{"digest": attestation, "artifactType": Bundle, "annotations": map[string]string{"dev.sigstore.bundle.predicateType": Provenance}},
		map[string]any{"digest": other, "artifactType": Bundle, "annotations": map[string]string{"dev.sigstore.bundle.predicateType": "https://spdx.dev/Document"}},
	}}, strings.Replace(index, ":", "-", 1))

	return index
}

func TestAnImageIsReadWithAnAnonymousToken(t *testing.T) {
	fake, client := newRegistry(t)
	index := fake.image(t)
	ctx := context.Background()

	digest, err := client.Digest(ctx, "ghcr.io/xixo/xixo", "main")
	if err != nil || digest != index {
		t.Fatalf("digest %s err %v", digest, err)
	}

	labels, err := client.Labels(ctx, "ghcr.io/xixo/xixo", digest)
	if err != nil || labels["org.opencontainers.image.revision"] != "c589ffe" {
		t.Fatalf("labels %v err %v", labels, err)
	}

	bundles, err := client.Bundles(ctx, "ghcr.io/xixo/xixo", digest)
	if err != nil || len(bundles) != 1 {
		t.Fatalf("%d bundles, err %v", len(bundles), err)
	}

	if fake.tokens != 1 {
		t.Fatalf("%d tokens", fake.tokens)
	}
}

func TestABlobThatDoesNotHashToItsDigestIsRefused(t *testing.T) {
	fake, client := newRegistry(t)
	index := fake.image(t)
	fake.lie = true

	if _, err := client.Labels(context.Background(), "ghcr.io/xixo/xixo", index); err == nil || !strings.Contains(err.Error(), "hashes to") {
		t.Fatalf("err %v", err)
	}
}

func TestAManifestAskedForByDigestMustHashToIt(t *testing.T) {
	fake, client := newRegistry(t)
	fake.image(t)
	wrong := "sha256:" + strings.Repeat("a", 64)
	fake.manifests[wrong] = fake.manifests["main"]

	if _, err := client.Labels(context.Background(), "ghcr.io/xixo/xixo", wrong); err == nil {
		t.Fatal("a manifest under the wrong digest was read")
	}
}

func TestAnImageWithNoAttestationsHasNoBundles(t *testing.T) {
	fake, client := newRegistry(t)
	config := fake.blob([]byte(`{}`))
	digest := fake.manifest(map[string]any{"mediaType": Manifest, "config": map[string]any{"digest": config}}, "main")

	bundles, err := client.Bundles(context.Background(), "ghcr.io/xixo/xixo", digest)
	if err != nil || len(bundles) != 0 {
		t.Fatalf("%d bundles, err %v", len(bundles), err)
	}
}

func TestNamesAndTagsAreChecked(t *testing.T) {
	_, client := newRegistry(t)
	ctx := context.Background()

	for _, image := range []string{"xixo", "ghcr.io/../etc", "ghcr.io/x//y", "GHCR.IO/x/y"} {
		if _, err := client.Digest(ctx, image, "main"); err == nil || !strings.Contains(err.Error(), "not an image name") {
			t.Fatalf("%s was asked for", image)
		}
	}

	if _, err := client.Digest(ctx, "ghcr.io/xixo/xixo", "../main"); err == nil {
		t.Fatal("a tag with a path was asked for")
	}

	if _, err := client.Digest(ctx, "ghcr.io/xixo/xixo", "missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err %v", err)
	}
}
