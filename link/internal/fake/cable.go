package fake

import (
	"context"
	"crypto"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	jose "github.com/go-jose/go-jose/v4"
)

type Proof struct {
	Method string `json:"htm"`
	Target string `json:"htu"`
	Hash   string `json:"ath"`
	Nonce  string `json:"nonce"`
}

type Cable struct {
	*httptest.Server

	T          *testing.T
	Token      string
	Thumbprint string
	Nonce      string
	Handle     func(*Socket)

	lock    sync.Mutex
	proofs  []Proof
	refused int
	uploads map[string][]byte
	relays  map[string]*relay
}

type relay struct {
	body  []byte
	piece int
	asked []int64
	idle  bool
}

func NewCable(t *testing.T, token, thumbprint string, handle func(*Socket)) *Cable {
	held := &Cable{T: t, Token: token, Thumbprint: thumbprint, Handle: handle}
	held.Server = httptest.NewServer(http.HandlerFunc(held.serve))
	t.Cleanup(held.Close)

	return held
}

func (c *Cable) Proofs() []Proof {
	c.lock.Lock()
	defer c.lock.Unlock()

	return append([]Proof(nil), c.proofs...)
}

func (c *Cable) Refused() int {
	c.lock.Lock()
	defer c.lock.Unlock()

	return c.refused
}

func (c *Cable) Stage(id string, body []byte) {
	c.lock.Lock()
	defer c.lock.Unlock()

	if c.uploads == nil {
		c.uploads = map[string][]byte{}
	}

	c.uploads[id] = body
}

func (c *Cable) StageRelayed(id string, body []byte, piece int) {
	c.lock.Lock()
	defer c.lock.Unlock()

	if c.relays == nil {
		c.relays = map[string]*relay{}
	}

	c.relays[id] = &relay{body: body, piece: piece}
}

func (c *Cable) Asked(id string) []int64 {
	c.lock.Lock()
	defer c.lock.Unlock()

	if held, ok := c.relays[id]; ok {
		return append([]int64(nil), held.asked...)
	}

	return nil
}

func (c *Cable) part(response http.ResponseWriter, request *http.Request, held *relay) {
	from, err := strconv.ParseInt(request.URL.Query().Get("from"), 10, 64)
	if err != nil || from < 0 || from > int64(len(held.body)) {
		http.Error(response, "from", http.StatusRequestedRangeNotSatisfiable)

		return
	}

	c.lock.Lock()
	held.asked = append(held.asked, from)
	held.idle = !held.idle
	idle := held.idle
	c.lock.Unlock()

	if idle || from == int64(len(held.body)) {
		response.WriteHeader(http.StatusNoContent)

		return
	}

	end := min(from+int64(held.piece), int64(len(held.body)))
	response.Header().Set("Content-Length", fmt.Sprint(end-from))
	response.Write(held.body[from:end])
}

func (c *Cable) serve(response http.ResponseWriter, request *http.Request) {
	if strings.HasPrefix(request.URL.Path, "/link/uploads/") {
		c.upload(response, request)

		return
	}

	if request.URL.Path != "/cable" {
		http.NotFound(response, request)

		return
	}

	proof, err := c.check(request, "/cable", true)
	if err != nil {
		c.lock.Lock()
		c.refused++
		c.lock.Unlock()

		if c.Nonce != "" {
			response.Header().Set("DPoP-Nonce", c.Nonce)
		}

		http.Error(response, err.Error(), http.StatusUnauthorized)

		return
	}

	c.lock.Lock()
	c.proofs = append(c.proofs, *proof)
	c.lock.Unlock()

	ws, err := websocket.Accept(response, request, &websocket.AcceptOptions{Subprotocols: []string{"actioncable-v1-json"}})
	if err != nil {
		c.T.Errorf("accept: %v", err)

		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(4 << 20)

	if ws.Subprotocol() != "actioncable-v1-json" {
		c.T.Errorf("xixo link asked for subprotocol %q", ws.Subprotocol())
	}

	c.Handle(&Socket{T: c.T, ws: ws})
}

func (c *Cable) upload(response http.ResponseWriter, request *http.Request) {
	if _, err := c.check(request, request.URL.Path, false); err != nil {
		c.lock.Lock()
		c.refused++
		c.lock.Unlock()

		if c.Nonce != "" {
			response.Header().Set("DPoP-Nonce", c.Nonce)
		}

		http.Error(response, err.Error(), http.StatusUnauthorized)

		return
	}

	id := strings.TrimPrefix(request.URL.Path, "/link/uploads/")

	c.lock.Lock()
	relayed, ok := c.relays[id]
	c.lock.Unlock()

	if ok {
		c.part(response, request, relayed)

		return
	}

	c.lock.Lock()
	body, ok := c.uploads[id]
	delete(c.uploads, id)
	c.lock.Unlock()

	if !ok {
		http.NotFound(response, request)

		return
	}

	response.Header().Set("Content-Length", fmt.Sprint(len(body)))
	response.Write(body)
}

func (c *Cable) check(request *http.Request, path string, origin bool) (*Proof, error) {
	if got := request.Header.Get("Authorization"); got != "DPoP "+c.Token {
		return nil, fmt.Errorf("authorization %q", got)
	}

	if got := request.Header.Get("Origin"); origin && got != c.URL {
		return nil, fmt.Errorf("origin %q", got)
	}

	signed, err := jose.ParseSigned(request.Header.Get("DPoP"), []jose.SignatureAlgorithm{jose.ES256})
	if err != nil {
		return nil, err
	}

	header := signed.Signatures[0].Protected
	if header.ExtraHeaders["typ"] != "dpop+jwt" || header.JSONWebKey == nil {
		return nil, fmt.Errorf("proof header %+v", header)
	}

	raw, err := signed.Verify(header.JSONWebKey)
	if err != nil {
		return nil, err
	}

	thumbprint, _ := header.JSONWebKey.Thumbprint(crypto.SHA256)
	if base64.RawURLEncoding.EncodeToString(thumbprint) != c.Thumbprint {
		return nil, fmt.Errorf("the proof is signed by another key")
	}

	proof := &Proof{}
	if err := json.Unmarshal(raw, proof); err != nil {
		return nil, err
	}

	sum := sha256.Sum256([]byte(c.Token))

	switch {
	case proof.Method != http.MethodGet:
		return nil, fmt.Errorf("htm %q", proof.Method)
	case proof.Target != c.URL+path:
		return nil, fmt.Errorf("htu %q", proof.Target)
	case proof.Hash != base64.RawURLEncoding.EncodeToString(sum[:]):
		return nil, fmt.Errorf("ath %q", proof.Hash)
	case c.Nonce != "" && proof.Nonce != c.Nonce:
		return nil, fmt.Errorf("nonce %q", proof.Nonce)
	}

	return proof, nil
}

type Command struct {
	Command    string `json:"command"`
	Identifier string `json:"identifier"`
	Data       string `json:"data"`
}

type Socket struct {
	T  *testing.T
	ws *websocket.Conn
}

func (s *Socket) Send(frame any) {
	raw, _ := json.Marshal(frame)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := s.ws.Write(ctx, websocket.MessageText, raw); err != nil {
		s.T.Errorf("send: %v", err)
	}
}

func (s *Socket) Next() (*Command, map[string]any) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, raw, err := s.ws.Read(ctx)
	if err != nil {
		s.fail("read: %v", err)
	}

	held := &Command{}
	if err := json.Unmarshal(raw, held); err != nil {
		s.fail("command %s: %v", raw, err)
	}

	data := map[string]any{}
	if held.Data != "" {
		decoder := json.NewDecoder(strings.NewReader(held.Data))
		decoder.UseNumber()

		if err := decoder.Decode(&data); err != nil {
			s.fail("data %s: %v", held.Data, err)
		}
	}

	return held, data
}

func (s *Socket) Read() ([]byte, error) {
	_, raw, err := s.ws.Read(context.Background())

	return raw, err
}

func (s *Socket) fail(format string, args ...any) {
	s.T.Helper()
	s.T.Errorf(format, args...)
	runtime.Goexit()
}

func (s *Socket) Fail(format string, args ...any) {
	s.T.Helper()
	s.fail(format, args...)
}

func (s *Socket) Subscribe(identifier string) {
	s.Send(map[string]string{"type": "welcome"})

	command, _ := s.Next()
	if command.Command != "subscribe" || command.Identifier != identifier {
		s.fail("expected a subscription, got %+v", command)
	}

	s.Send(map[string]string{"type": "confirm_subscription", "identifier": identifier})
}

func (s *Socket) Ask(identifier string, message any) {
	s.Send(map[string]any{"identifier": identifier, "message": message})
}

func (s *Socket) Close() {
	s.ws.Close(websocket.StatusNormalClosure, "")
}
