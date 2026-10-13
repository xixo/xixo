package link

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/xixo/xixo/link/internal/machine"
)

const (
	MostRelayed       = 20 << 20
	MostRelayReply    = 3<<20 + 512<<10
	RelayedWithin     = 120 * time.Second
	MostRelayedWithin = 900 * time.Second
)

var (
	ErrRelayPort = errors.New("xixo link passes on only to the port of a model server it knows")
	ErrRelayPath = errors.New("xixo link passes on only what xixo asks a model server: its models, chat, completions, and embeddings")
	ErrRelaySize = fmt.Errorf("a request passed on to a model server holds at most %d bytes", MostRelayed)
)

var relayedPaths = map[string]string{
	"/v1/models":           http.MethodGet,
	"/v1/chat/completions": http.MethodPost,
	"/v1/completions":      http.MethodPost,
	"/v1/embeddings":       http.MethodPost,
	"/api/ps":              http.MethodGet,
	"/api/tags":            http.MethodGet,
	"/api/version":         http.MethodGet,
	"/api/show":            http.MethodPost,
}

type Relayed struct {
	Port          int    `json:"port"`
	Method        string `json:"method"`
	Path          string `json:"path"`
	Body          string `json:"body,omitempty"`
	Authorization string `json:"authorization,omitempty"`
	Within        int    `json:"within,omitempty"`
}

type RelayAnswer struct {
	Status      int    `json:"status"`
	ContentType string `json:"content_type"`
	Body        string `json:"body"`
}

func (a *Link) modelPortKnown(port int) bool {
	for _, held := range a.ModelPorts {
		if held == port {
			return true
		}
	}

	if a.ModelPorts != nil {
		return false
	}

	for _, known := range machine.Known {
		if known.Port == port {
			return true
		}
	}

	return false
}

func (a *Link) relay(ctx context.Context, raw json.RawMessage) (any, error) {
	wanted := Relayed{}
	if err := strictly(raw, &wanted); err != nil {
		return nil, err
	}

	if wanted.Port < 1 || wanted.Port > 65535 || !a.modelPortKnown(wanted.Port) {
		return nil, ErrRelayPort
	}

	if method, ok := relayedPaths[wanted.Path]; !ok || method != wanted.Method {
		return nil, ErrRelayPath
	}

	if len(wanted.Body) > MostRelayed || len(wanted.Authorization) > 4096 {
		return nil, ErrRelaySize
	}

	within := RelayedWithin
	if wanted.Within > 0 {
		within = min(time.Duration(wanted.Within)*time.Second, MostRelayedWithin)
	}

	ctx, cancel := context.WithTimeout(ctx, within)
	defer cancel()

	var sent io.Reader
	if wanted.Method == http.MethodPost {
		sent = bytes.NewReader([]byte(wanted.Body))
	}

	request, err := http.NewRequestWithContext(ctx, wanted.Method, "http://127.0.0.1:"+strconv.Itoa(wanted.Port)+wanted.Path, sent)
	if err != nil {
		return nil, err
	}

	request.Header.Set("User-Agent", "xixo-link")
	if wanted.Method == http.MethodPost {
		request.Header.Set("Content-Type", "application/json")
	}

	if wanted.Authorization != "" {
		request.Header.Set("Authorization", wanted.Authorization)
	}

	response, err := relayClient(wanted.Port, within).Do(request)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrNoModelServer, err)
	}
	defer response.Body.Close()

	read, err := io.ReadAll(io.LimitReader(response.Body, MostRelayReply+1))
	if err != nil {
		return nil, err
	}

	if len(read) > MostRelayReply {
		return nil, fmt.Errorf("the model server answered with more than %d bytes", MostRelayReply)
	}

	return RelayAnswer{Status: response.StatusCode, ContentType: response.Header.Get("Content-Type"), Body: string(read)}, nil
}

func relayClient(port int, within time.Duration) *http.Client {
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	dialer := &net.Dialer{Timeout: 5 * time.Second}

	return &http.Client{
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, "tcp4", address)
			},
			MaxResponseHeaderBytes: 64 << 10,
			ResponseHeaderTimeout:  within,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}
