package updates

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

const MostRequest = 16 << 20

func (g *Gate) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		held, err := g.Status(r.Context())
		answer(w, held, err)
	})

	mux.HandleFunc("GET /idle", func(w http.ResponseWriter, r *http.Request) {
		if g.Idle() {
			answer(w, map[string]bool{"idle": true}, nil)
			return
		}

		answer(w, nil, errors.New("the gate is pulling, swapping, or rolling back"))
	})

	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) {
		answer(w, map[string]bool{"ready": true}, g.Ready(r.Context()))
	})

	mux.HandleFunc("POST /pull", func(w http.ResponseWriter, r *http.Request) {
		request, err := read(r)
		if err == nil {
			err = g.Pull(context.WithoutCancel(r.Context()), request)
		}
		answer(w, map[string]bool{"pulled": true}, err)
	})

	mux.HandleFunc("POST /swap", func(w http.ResponseWriter, r *http.Request) {
		request, err := read(r)
		if err == nil {
			err = g.Swap(context.WithoutCancel(r.Context()), request)
		}
		answer(w, map[string]bool{"swapped": true}, err)
	})

	mux.HandleFunc("POST /rollback", func(w http.ResponseWriter, r *http.Request) {
		request, err := read(r)
		if err == nil {
			err = g.Rollback(context.WithoutCancel(r.Context()), request.Kind)
		}
		answer(w, map[string]bool{"rolled_back": true}, err)
	})

	return mux
}

func read(r *http.Request) (Request, error) {
	decoder := json.NewDecoder(http.MaxBytesReader(nil, r.Body, MostRequest))
	decoder.DisallowUnknownFields()

	held := Request{}
	if err := decoder.Decode(&held); err != nil {
		return Request{}, fmt.Errorf("the request is not one the gate takes: %w", err)
	}

	return held, nil
}

func answer(w http.ResponseWriter, held any, err error) {
	w.Header().Set("Content-Type", "application/json")

	if err != nil {
		w.WriteHeader(http.StatusConflict)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	json.NewEncoder(w).Encode(held)
}

func Listen(path string) (net.Listener, error) {
	os.Remove(path)

	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}

	if err := os.Chmod(path, 0o666); err != nil {
		listener.Close()
		return nil, err
	}

	return listener, nil
}

type Remote struct {
	HTTP *http.Client
}

func Dial(path string) *Remote {
	return &Remote{HTTP: &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		},
	}}}
}

func (r *Remote) call(ctx context.Context, method, path string, body any, held any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}

		reader = bytes.NewReader(raw)
	}

	request, err := http.NewRequestWithContext(ctx, method, "http://gate"+path, reader)
	if err != nil {
		return err
	}

	response, err := r.HTTP.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		said := struct {
			Error string `json:"error"`
		}{}
		json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&said)
		if said.Error == "" {
			said.Error = response.Status
		}

		return errors.New(said.Error)
	}

	if held == nil {
		return nil
	}

	return json.NewDecoder(io.LimitReader(response.Body, MostRequest)).Decode(held)
}

func (r *Remote) Status(ctx context.Context) ([]Held, error) {
	held := []Held{}
	err := r.call(ctx, http.MethodGet, "/status", nil, &held)

	return held, err
}

func (r *Remote) Idle(ctx context.Context) error {
	return r.call(ctx, http.MethodGet, "/idle", nil, nil)
}

func (r *Remote) Ready(ctx context.Context) error {
	return r.call(ctx, http.MethodGet, "/ready", nil, nil)
}

func (r *Remote) Pull(ctx context.Context, request Request) error {
	return r.call(ctx, http.MethodPost, "/pull", request, nil)
}

func (r *Remote) Swap(ctx context.Context, request Request) error {
	return r.call(ctx, http.MethodPost, "/swap", request, nil)
}

func (r *Remote) Rollback(ctx context.Context, kind string) error {
	return r.call(ctx, http.MethodPost, "/rollback", Request{Kind: kind}, nil)
}

func Serve(ctx context.Context, listener net.Listener, handler http.Handler) error {
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}

	go func() {
		<-ctx.Done()
		server.Close()
	}()

	err := server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}

	return err
}
