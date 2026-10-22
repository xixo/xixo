package updates

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/xixo/xixo/link/internal/verify"
)

const (
	built   = "sha256:714a1360649077ded84650e6bd5369e5ccca0531de47192dc4e05d1fd6d6ef1a"
	running = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
)

type fakeImage struct {
	ID      string
	Digests []string
	Labels  map[string]string
	Env     []string
	Health  string
	Cmd     []string
}

type fakeContainer struct {
	ID       string
	Name     string
	Config   map[string]any
	Host     map[string]any
	Networks map[string]any
	Image    string
	Running  bool
	Health   string
}

type fakeDocker struct {
	t          *testing.T
	lock       sync.Mutex
	images     map[string]*fakeImage
	tags       map[string]string
	published  map[string]*fakeImage
	containers []*fakeContainer
	next       int
	pulls      []string
}

func newDocker(t *testing.T) (*fakeDocker, *Docker) {
	t.Helper()
	fake := &fakeDocker{t: t, images: map[string]*fakeImage{}, tags: map[string]string{}, published: map[string]*fakeImage{}}
	dir, err := os.MkdirTemp("", "docker")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })

	path := filepath.Join(dir, "docker.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}

	server := &http.Server{Handler: http.StripPrefix(API, fake.mux())}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })

	return fake, Socket(path)
}

func (f *fakeDocker) image(held *fakeImage, tags ...string) {
	f.lock.Lock()
	defer f.lock.Unlock()

	f.images[held.ID] = held
	for _, tag := range tags {
		f.tags[tag] = held.ID
	}
}

func (f *fakeDocker) resolve(name string) *fakeImage {
	if held := f.images[name]; held != nil {
		return held
	}

	if id, found := f.tags[name]; found {
		return f.images[id]
	}

	for _, held := range f.images {
		for _, digest := range held.Digests {
			if digest == name {
				return held
			}
		}
	}

	return nil
}

func (f *fakeDocker) container(name string) *fakeContainer {
	for _, held := range f.containers {
		if held.ID == name || held.Name == name || held.Name == "/"+name {
			return held
		}
	}

	return nil
}

func (f *fakeDocker) run(name, service, image string, order string, env []string) *fakeContainer {
	f.lock.Lock()
	defer f.lock.Unlock()

	held := f.resolve(image)
	f.next++
	id := fmt.Sprintf("%012d%052d", f.next, 0)
	labels := map[string]any{Label: strings.Split(strings.TrimPrefix(image, LocalRepo), ":")[0], "com.docker.compose.service": service, "com.docker.compose.image": held.ID}
	for key, value := range held.Labels {
		labels[key] = value
	}
	if order != "" {
		labels[OrderLabel] = order
	}

	container := &fakeContainer{
		ID: id, Name: "/" + name, Image: held.ID, Running: true, Health: held.Health,
		Config: map[string]any{
			"Image": image, "Hostname": id[:12], "Env": toAny(append(append([]string{}, held.Env...), env...)),
			"Labels": labels, "Cmd": toAny(held.Cmd),
		},
		Host:     map[string]any{"Binds": []any{"files:/data/files"}, "RestartPolicy": map[string]any{"Name": "unless-stopped"}},
		Networks: map[string]any{"xixo_default": map[string]any{"Aliases": []any{service, id[:12]}}},
	}
	f.containers = append(f.containers, container)

	return container
}

func toAny(list []string) []any {
	held := []any{}
	for _, item := range list {
		held = append(held, item)
	}

	return held
}

func (f *fakeDocker) imageJSON(held *fakeImage) map[string]any {
	return map[string]any{"Id": held.ID, "RepoDigests": held.Digests, "Config": map[string]any{"Labels": held.Labels, "Env": held.Env, "Cmd": held.Cmd}}
}

func (f *fakeDocker) containerJSON(held *fakeContainer) map[string]any {
	state := map[string]any{"Running": held.Running, "Restarting": false, "Status": map[bool]string{true: "running", false: "exited"}[held.Running]}
	if held.Health != "" && held.Running {
		state["Health"] = map[string]any{"Status": held.Health}
	}

	return map[string]any{
		"Id": held.ID, "Name": held.Name, "Image": held.Image, "Config": held.Config, "HostConfig": held.Host,
		"State": state, "RestartCount": 0, "NetworkSettings": map[string]any{"Networks": held.Networks},
		"Mounts": []any{map[string]any{"Type": "volume", "Name": "files", "Destination": "/data/files"}},
	}
}

func (f *fakeDocker) mux() http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, held any) { json.NewEncoder(w).Encode(held) }
	missing := func(w http.ResponseWriter) { http.Error(w, `{"message":"no such thing"}`, http.StatusNotFound) }

	mux.HandleFunc("GET /images/{name}/json", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		if held := f.resolve(r.PathValue("name")); held != nil {
			reply(w, f.imageJSON(held))
			return
		}
		missing(w)
	})

	mux.HandleFunc("POST /images/create", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		reference := r.URL.Query().Get("fromImage")
		f.pulls = append(f.pulls, reference)
		held := f.published[reference]
		if held == nil {
			fmt.Fprintln(w, `{"error":"manifest unknown"}`)
			return
		}
		f.images[held.ID] = held
		fmt.Fprintln(w, `{"status":"Downloaded newer image"}`)
	})

	mux.HandleFunc("POST /images/{name}/tag", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		held := f.resolve(r.PathValue("name"))
		if held == nil {
			missing(w)
			return
		}
		f.tags[r.URL.Query().Get("repo")+":"+r.URL.Query().Get("tag")] = held.ID
		w.WriteHeader(http.StatusCreated)
	})

	mux.HandleFunc("GET /containers/json", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		listed := []map[string]any{}
		for _, held := range f.containers {
			labels := held.Config["Labels"].(map[string]any)
			if _, found := labels[Label]; !found {
				continue
			}
			listed = append(listed, map[string]any{"Id": held.ID, "Names": []string{held.Name}, "Image": held.Image, "State": map[bool]string{true: "running", false: "exited"}[held.Running], "Labels": labels})
		}
		reply(w, listed)
	})

	mux.HandleFunc("GET /containers/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		if held := f.container(r.PathValue("id")); held != nil {
			reply(w, f.containerJSON(held))
			return
		}
		missing(w)
	})

	mux.HandleFunc("POST /containers/create", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		name := r.URL.Query().Get("name")
		if f.container(name) != nil {
			http.Error(w, `{"message":"name in use"}`, http.StatusConflict)
			return
		}
		body := map[string]any{}
		json.NewDecoder(r.Body).Decode(&body)
		reference, _ := body["Image"].(string)
		held := f.resolve(reference)
		if held == nil {
			missing(w)
			return
		}
		host, _ := body["HostConfig"].(map[string]any)
		networks := map[string]any{}
		if config, ok := body["NetworkingConfig"].(map[string]any); ok {
			networks, _ = config["EndpointsConfig"].(map[string]any)
		}
		delete(body, "HostConfig")
		delete(body, "NetworkingConfig")
		env := toAny(held.Env)
		if listed, ok := body["Env"].([]any); ok {
			env = append(env, listed...)
		}
		body["Env"] = env
		if _, found := body["Cmd"]; !found {
			body["Cmd"] = toAny(held.Cmd)
		}
		labels, _ := body["Labels"].(map[string]any)
		for key, value := range held.Labels {
			if _, found := labels[key]; !found {
				labels[key] = value
			}
		}
		f.next++
		id := fmt.Sprintf("%012d%052d", f.next, 0)
		f.containers = append(f.containers, &fakeContainer{ID: id, Name: "/" + name, Config: body, Host: host, Networks: networks, Image: held.ID, Health: held.Health})
		w.WriteHeader(http.StatusCreated)
		reply(w, map[string]string{"Id": id})
	})

	mux.HandleFunc("POST /containers/{id}/start", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		held := f.container(r.PathValue("id"))
		if held == nil {
			missing(w)
			return
		}
		held.Running = true
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /containers/{id}/stop", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		held := f.container(r.PathValue("id"))
		if held == nil {
			missing(w)
			return
		}
		held.Running = false
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /containers/{id}/rename", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		held := f.container(r.PathValue("id"))
		if held == nil {
			missing(w)
			return
		}
		wanted := r.URL.Query().Get("name")
		if other := f.container(wanted); other != nil && other != held {
			http.Error(w, `{"message":"name in use"}`, http.StatusConflict)
			return
		}
		held.Name = "/" + wanted
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("DELETE /containers/{id}", func(w http.ResponseWriter, r *http.Request) {
		f.lock.Lock()
		defer f.lock.Unlock()
		held := f.container(r.PathValue("id"))
		if held == nil {
			missing(w)
			return
		}
		kept := []*fakeContainer{}
		for _, other := range f.containers {
			if other != held {
				kept = append(kept, other)
			}
		}
		f.containers = kept
		w.WriteHeader(http.StatusNoContent)
	})

	return mux
}

func trusted(t *testing.T) func() (*verify.Checker, error) {
	t.Helper()
	held, err := root.NewTrustedRootFromPath("../verify/testdata/trusted_root.json")
	if err != nil {
		t.Fatal(err)
	}

	return func() (*verify.Checker, error) { return &verify.Checker{Trusted: held}, nil }
}

func bundle(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile("../verify/testdata/xixo.sigstore.json")
	if err != nil {
		t.Fatal(err)
	}

	return raw
}
