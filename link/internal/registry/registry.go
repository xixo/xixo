package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

const (
	MostManifest = 4 << 20
	MostBundles  = 8
	MostTags     = 10000
	Index        = "application/vnd.oci.image.index.v1+json"
	Manifest     = "application/vnd.oci.image.manifest.v1+json"
	DockerList   = "application/vnd.docker.distribution.manifest.list.v2+json"
	DockerImage  = "application/vnd.docker.distribution.manifest.v2+json"
	Bundle       = "application/vnd.dev.sigstore.bundle.v0.3+json"
	Provenance   = "https://slsa.dev/provenance/v1"
)

var (
	ErrNotFound = errors.New("the registry has no such image")
	digestShape = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	nameShape   = regexp.MustCompile(`^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$`)
	tagShape    = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)
)

type Client struct {
	HTTP *http.Client
	Base func(host string) string

	lock   sync.Mutex
	tokens map[string]string
}

type descriptor struct {
	MediaType    string            `json:"mediaType"`
	Digest       string            `json:"digest"`
	Size         int64             `json:"size"`
	ArtifactType string            `json:"artifactType"`
	Annotations  map[string]string `json:"annotations"`
	Platform     *struct {
		OS           string `json:"os"`
		Architecture string `json:"architecture"`
	} `json:"platform"`
}

type manifest struct {
	MediaType string       `json:"mediaType"`
	Manifests []descriptor `json:"manifests"`
	Config    descriptor   `json:"config"`
	Layers    []descriptor `json:"layers"`
}

func split(image string) (string, string, error) {
	if !nameShape.MatchString(image) || strings.Contains(image, "..") || strings.Contains(image, "//") {
		return "", "", fmt.Errorf("%q is not an image name", image)
	}

	host, name, _ := strings.Cut(image, "/")

	return host, name, nil
}

func (c *Client) client() *http.Client {
	if c.HTTP == nil {
		return &http.Client{Timeout: 60 * time.Second}
	}

	return c.HTTP
}

func (c *Client) base(host string) string {
	if c.Base != nil {
		return c.Base(host)
	}

	return "https://" + host
}

func (c *Client) Digest(ctx context.Context, image, tag string) (string, error) {
	if !tagShape.MatchString(tag) {
		return "", fmt.Errorf("%q is not a tag", tag)
	}

	_, digest, err := c.manifest(ctx, image, tag)

	return digest, err
}

func (c *Client) Tags(ctx context.Context, image string) ([]string, error) {
	host, name, err := split(image)
	if err != nil {
		return nil, err
	}

	held := struct {
		Tags []string `json:"tags"`
	}{}

	raw, _, err := c.get(ctx, host, name, "/v2/"+name+"/tags/list?n="+fmt.Sprint(MostTags), "application/json", MostManifest)
	if err != nil {
		return nil, err
	}

	if err := json.Unmarshal(raw, &held); err != nil {
		return nil, err
	}

	return held.Tags, nil
}

func (c *Client) Labels(ctx context.Context, image, digest string) (map[string]string, error) {
	if !digestShape.MatchString(digest) {
		return nil, fmt.Errorf("%q is not a digest", digest)
	}

	host, name, err := split(image)
	if err != nil {
		return nil, err
	}

	held, _, err := c.manifest(ctx, image, digest)
	if err != nil {
		return nil, err
	}

	if held.MediaType == Index || held.MediaType == DockerList {
		chosen := ""
		for _, entry := range held.Manifests {
			if entry.Platform != nil && entry.Platform.OS == "linux" && entry.Platform.Architecture == runtime.GOARCH {
				chosen = entry.Digest
				break
			}
		}

		if chosen == "" {
			return nil, fmt.Errorf("%s@%s has no build for linux/%s", image, digest, runtime.GOARCH)
		}

		if held, _, err = c.manifest(ctx, image, chosen); err != nil {
			return nil, err
		}
	}

	if !digestShape.MatchString(held.Config.Digest) {
		return nil, fmt.Errorf("%s@%s names no config", image, digest)
	}

	raw, err := c.blob(ctx, host, name, held.Config.Digest, MostManifest)
	if err != nil {
		return nil, err
	}

	config := struct {
		Config struct {
			Labels map[string]string `json:"Labels"`
		} `json:"config"`
	}{}

	if err := json.Unmarshal(raw, &config); err != nil {
		return nil, err
	}

	return config.Config.Labels, nil
}

func (c *Client) Bundles(ctx context.Context, image, digest string) ([][]byte, error) {
	if !digestShape.MatchString(digest) {
		return nil, fmt.Errorf("%q is not a digest", digest)
	}

	host, name, err := split(image)
	if err != nil {
		return nil, err
	}

	index, _, err := c.manifest(ctx, image, strings.Replace(digest, ":", "-", 1))
	if errors.Is(err, ErrNotFound) {
		return nil, nil
	}

	if err != nil {
		return nil, err
	}

	held := [][]byte{}

	for _, entry := range index.Manifests {
		if len(held) == MostBundles {
			break
		}

		if entry.ArtifactType != Bundle || entry.Annotations["dev.sigstore.bundle.predicateType"] != Provenance || !digestShape.MatchString(entry.Digest) {
			continue
		}

		attestation, _, err := c.manifest(ctx, image, entry.Digest)
		if err != nil || len(attestation.Layers) != 1 || attestation.Layers[0].MediaType != Bundle {
			continue
		}

		raw, err := c.blob(ctx, host, name, attestation.Layers[0].Digest, MostManifest)
		if err == nil {
			held = append(held, raw)
		}
	}

	return held, nil
}

func (c *Client) manifest(ctx context.Context, image, reference string) (manifest, string, error) {
	host, name, err := split(image)
	if err != nil {
		return manifest{}, "", err
	}

	raw, digest, err := c.get(ctx, host, name, "/v2/"+name+"/manifests/"+url.PathEscape(reference),
		strings.Join([]string{Index, Manifest, DockerList, DockerImage}, ", "), MostManifest)
	if err != nil {
		return manifest{}, "", err
	}

	if digestShape.MatchString(reference) && digest != reference {
		return manifest{}, "", fmt.Errorf("%s answered %s for %s", image, digest, reference)
	}

	held := manifest{}
	if err := json.Unmarshal(raw, &held); err != nil {
		return manifest{}, "", err
	}

	return held, digest, nil
}

func (c *Client) blob(ctx context.Context, host, name, digest string, most int64) ([]byte, error) {
	if !digestShape.MatchString(digest) {
		return nil, fmt.Errorf("%q is not a digest", digest)
	}

	raw, sum, err := c.get(ctx, host, name, "/v2/"+name+"/blobs/"+digest, "*/*", most)
	if err != nil {
		return nil, err
	}

	if sum != digest {
		return nil, fmt.Errorf("the blob %s hashes to %s", digest, sum)
	}

	return raw, nil
}

func (c *Client) get(ctx context.Context, host, name, path, accept string, most int64) ([]byte, string, error) {
	for attempt := 0; attempt < 2; attempt++ {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base(host)+path, nil)
		if err != nil {
			return nil, "", err
		}

		request.Header.Set("Accept", accept)
		if token := c.token(host, name); token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}

		response, err := c.client().Do(request)
		if err != nil {
			return nil, "", err
		}

		raw, err := io.ReadAll(io.LimitReader(response.Body, most+1))
		response.Body.Close()

		switch {
		case err != nil:
			return nil, "", err
		case response.StatusCode == http.StatusUnauthorized && attempt == 0:
			if err := c.authorize(ctx, host, name, response.Header.Get("WWW-Authenticate")); err != nil {
				return nil, "", err
			}

			continue
		case response.StatusCode == http.StatusNotFound:
			return nil, "", fmt.Errorf("%w: %s/%s %s", ErrNotFound, host, name, path)
		case response.StatusCode != http.StatusOK:
			return nil, "", fmt.Errorf("%s answered %d for %s", host, response.StatusCode, path)
		case int64(len(raw)) > most:
			return nil, "", fmt.Errorf("%s answered more than %d bytes for %s", host, most, path)
		}

		return raw, sha(raw), nil
	}

	return nil, "", fmt.Errorf("%s refused an anonymous pull of %s", host, name)
}
