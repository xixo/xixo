package updates

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const API = "/v1.47"

var ErrNoImage = errors.New("docker holds no such image")

type Docker struct {
	HTTP *http.Client
}

type Image struct {
	keyed map[string]bool

	ID          string   `json:"Id"`
	RepoDigests []string `json:"RepoDigests"`
	Config      struct {
		Labels      map[string]string   `json:"Labels"`
		Env         []string            `json:"Env"`
		Cmd         []string            `json:"Cmd"`
		Entrypoint  []string            `json:"Entrypoint"`
		WorkingDir  string              `json:"WorkingDir"`
		User        string              `json:"User"`
		StopSignal  string              `json:"StopSignal"`
		Healthcheck json.RawMessage     `json:"Healthcheck"`
		Exposed     map[string]struct{} `json:"ExposedPorts"`
		Volumes     map[string]struct{} `json:"Volumes"`
	} `json:"Config"`
}

type Listed struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	Image  string            `json:"Image"`
	State  string            `json:"State"`
	Labels map[string]string `json:"Labels"`
}

func Socket(path string) *Docker {
	return &Docker{HTTP: &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		},
	}}}
}

func (d *Docker) call(ctx context.Context, method, path string, body any, held any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}

		reader = bytes.NewReader(raw)
	}

	request, err := http.NewRequestWithContext(ctx, method, "http://docker"+API+path, reader)
	if err != nil {
		return err
	}

	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := d.HTTP.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusNotFound {
		return fmt.Errorf("%w: %s", ErrNoImage, path)
	}

	if response.StatusCode >= 300 && response.StatusCode != http.StatusNotModified {
		said, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("docker answered %d to %s %s: %s", response.StatusCode, method, path, strings.TrimSpace(string(said)))
	}

	if held == nil {
		_, err := io.Copy(io.Discard, response.Body)
		return err
	}

	return json.NewDecoder(response.Body).Decode(held)
}

func (d *Docker) Image(ctx context.Context, name string) (Image, error) {
	held := Image{}
	err := d.call(ctx, http.MethodGet, "/images/"+url.PathEscape(name)+"/json", nil, &held)

	return held, err
}

func (d *Docker) Pull(ctx context.Context, image, digest string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"http://docker"+API+"/images/create?"+url.Values{"fromImage": {image + "@" + digest}}.Encode(), nil)
	if err != nil {
		return err
	}

	response, err := d.HTTP.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		said, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("docker could not pull %s@%s: %s", image, digest, strings.TrimSpace(string(said)))
	}

	lines := bufio.NewScanner(response.Body)
	lines.Buffer(make([]byte, 64<<10), 1<<20)

	for lines.Scan() {
		said := struct {
			Error string `json:"error"`
		}{}

		if json.Unmarshal(lines.Bytes(), &said) == nil && said.Error != "" {
			return fmt.Errorf("docker could not pull %s@%s: %s", image, digest, said.Error)
		}
	}

	return lines.Err()
}

func (d *Docker) Tag(ctx context.Context, source, target string) error {
	repo, tag, _ := strings.Cut(target, ":")

	return d.call(ctx, http.MethodPost, "/images/"+url.PathEscape(source)+"/tag?"+url.Values{"repo": {repo}, "tag": {tag}}.Encode(), nil, nil)
}

func (d *Docker) Labeled(ctx context.Context) ([]Listed, error) {
	filters, _ := json.Marshal(map[string][]string{"label": {Label}})
	held := []Listed{}
	err := d.call(ctx, http.MethodGet, "/containers/json?"+url.Values{"all": {"1"}, "filters": {string(filters)}}.Encode(), nil, &held)

	return held, err
}

func (d *Docker) Inspect(ctx context.Context, id string) (map[string]any, error) {
	held := map[string]any{}
	err := d.call(ctx, http.MethodGet, "/containers/"+url.PathEscape(id)+"/json", nil, &held)

	return held, err
}

func (d *Docker) Create(ctx context.Context, name string, body map[string]any) (string, error) {
	held := struct {
		ID string `json:"Id"`
	}{}
	err := d.call(ctx, http.MethodPost, "/containers/create?"+url.Values{"name": {name}}.Encode(), body, &held)

	return held.ID, err
}

func (d *Docker) Start(ctx context.Context, id string) error {
	return d.call(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/start", nil, nil)
}

func (d *Docker) Stop(ctx context.Context, id string, within time.Duration) error {
	return d.call(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/stop?t="+fmt.Sprint(int(within.Seconds())), nil, nil)
}

func (d *Docker) Rename(ctx context.Context, id, name string) error {
	return d.call(ctx, http.MethodPost, "/containers/"+url.PathEscape(id)+"/rename?"+url.Values{"name": {name}}.Encode(), nil, nil)
}

func (d *Docker) Remove(ctx context.Context, id string) error {
	return d.call(ctx, http.MethodDelete, "/containers/"+url.PathEscape(id)+"?force=1", nil, nil)
}
