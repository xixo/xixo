package cable

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/coder/websocket"
	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/dial"
)

const (
	Protocol = "actioncable-v1-json"
	Path     = "/cable"
)

var ErrRejected = errors.New("xixo refused the subscription")

const UnknownMachine = "unknown_machine"

type Frame struct {
	Type       string          `json:"type,omitempty"`
	Identifier string          `json:"identifier,omitempty"`
	Message    json.RawMessage `json:"message,omitempty"`
	Reason     string          `json:"reason,omitempty"`
	Reconnect  *bool           `json:"reconnect,omitempty"`
}

type command struct {
	Command    string `json:"command"`
	Identifier string `json:"identifier"`
	Data       string `json:"data,omitempty"`
}

type Disconnected struct {
	Reason    string
	Reconnect bool
}

func (d *Disconnected) Error() string {
	if !d.Reconnect {
		return "xixo closed the connection for good: " + d.Reason
	}

	return "xixo closed the connection: " + d.Reason
}

func (d *Disconnected) Withdrawn() bool {
	return d.Reason == UnknownMachine && !d.Reconnect
}

const Handshake = 30 * time.Second

type Conn struct {
	ws         *websocket.Conn
	identifier string
}

func Endpoints(xixo string) (socket, target, origin string, err error) {
	parsed, err := url.Parse(strings.TrimSuffix(xixo, "/"))
	if err != nil {
		return "", "", "", err
	}

	origin = parsed.Scheme + "://" + parsed.Host
	target = origin + Path

	switch parsed.Scheme {
	case "https":
		socket = "wss://" + parsed.Host + Path
	case "http":
		socket = "ws://" + parsed.Host + Path
	default:
		return "", "", "", fmt.Errorf("%q is not an http or https address", xixo)
	}

	return socket, target, origin, nil
}

func Dial(ctx context.Context, xixo string, token *masks.Token, dpop *masks.Key, channel string) (*Conn, error) {
	socket, target, origin, err := Endpoints(xixo)
	if err != nil {
		return nil, err
	}

	nonce := ""

	for attempt := 0; ; attempt++ {
		proof, err := dpop.Proof(http.MethodGet, target, token.AccessToken, nonce)
		if err != nil {
			return nil, err
		}

		header := http.Header{}
		header.Set("Authorization", "DPoP "+token.AccessToken)
		header.Set("DPoP", proof)
		header.Set("Origin", origin)

		ws, response, err := websocket.Dial(ctx, socket, &websocket.DialOptions{
			HTTPClient:   dial.Client(Handshake),
			HTTPHeader:   header,
			Subprotocols: []string{Protocol},
		})

		if err == nil {
			ws.SetReadLimit(4 << 20)
			identifier, _ := json.Marshal(map[string]string{"channel": channel})

			return &Conn{ws: ws, identifier: string(identifier)}, nil
		}

		wanted := ""
		if response != nil {
			wanted = response.Header.Get("DPoP-Nonce")
		}

		if attempt > 0 || wanted == "" || wanted == nonce {
			return nil, err
		}

		nonce = wanted
	}
}

func (c *Conn) Close() error {
	return c.ws.Close(websocket.StatusNormalClosure, "")
}

func (c *Conn) Identifier() string {
	return c.identifier
}

func (c *Conn) Receive(ctx context.Context) (*Frame, error) {
	_, raw, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}

	held := &Frame{}
	if err := json.Unmarshal(raw, held); err != nil {
		return nil, fmt.Errorf("xixo sent a frame that is not JSON: %w", err)
	}

	if held.Type == "disconnect" {
		return nil, &Disconnected{Reason: held.Reason, Reconnect: held.Reconnect == nil || *held.Reconnect}
	}

	return held, nil
}

func (c *Conn) Subscribe(ctx context.Context, wait time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()

	welcomed := false

	for {
		frame, err := c.Receive(ctx)
		if err != nil {
			return err
		}

		switch frame.Type {
		case "welcome":
			if welcomed {
				continue
			}

			welcomed = true

			if err := c.send(ctx, command{Command: "subscribe", Identifier: c.identifier}); err != nil {
				return err
			}
		case "confirm_subscription":
			if frame.Identifier == c.identifier {
				return nil
			}
		case "reject_subscription":
			if frame.Identifier == c.identifier {
				return ErrRejected
			}
		}
	}
}

func (c *Conn) Perform(ctx context.Context, action string, payload any) error {
	data, err := Data(action, payload)
	if err != nil {
		return err
	}

	return c.send(ctx, command{Command: "message", Identifier: c.identifier, Data: data})
}

func Data(action string, payload any) (string, error) {
	named, err := json.Marshal(action)
	if err != nil {
		return "", err
	}

	raw := []byte("{}")

	if payload != nil {
		raw, err = json.Marshal(payload)
		if err != nil {
			return "", err
		}
	}

	body := strings.TrimSpace(string(raw))
	if !strings.HasPrefix(body, "{") || !strings.HasSuffix(body, "}") {
		return "", fmt.Errorf("a %s payload is not an object", action)
	}

	rest := strings.TrimSpace(body[1 : len(body)-1])
	if rest == "" {
		return `{"action":` + string(named) + `}`, nil
	}

	return `{"action":` + string(named) + `,` + rest + `}`, nil
}

func (c *Conn) send(ctx context.Context, sent command) error {
	raw, err := json.Marshal(sent)
	if err != nil {
		return err
	}

	return c.ws.Write(ctx, websocket.MessageText, raw)
}
