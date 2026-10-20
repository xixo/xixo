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
	"strings"
	"time"
	"unicode/utf8"

	"github.com/xixo/xixo/link/internal/machine"
)

const (
	MostMessages     = 32
	MostPrompt       = 64 << 10
	MostAnswer       = 64 << 10
	MostModelReply   = 1 << 20
	MostTokens       = 4096
	DefaultTokens    = 1024
	AnsweredWithin   = 90 * time.Second
	modelsListedFrom = "/v1/models"
	chatFrom         = "/v1/chat/completions"
)

var (
	ErrNoModelServer = errors.New("this machine runs no model server of that kind")
	ErrRole          = errors.New("each message is from system, user, or assistant")
	ErrPrompt        = fmt.Errorf("a prompt holds 1 to %d messages and at most %d bytes", MostMessages, MostPrompt)
	ErrNoModel       = errors.New("the model server names no model to answer with")
)

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type Prompt struct {
	Kind      string    `json:"kind"`
	Model     string    `json:"model,omitempty"`
	Messages  []Message `json:"messages"`
	MaxTokens int       `json:"max_tokens,omitempty"`
}

type Answered struct {
	Kind      string `json:"kind"`
	Model     string `json:"model"`
	Text      string `json:"text"`
	Truncated bool   `json:"truncated,omitempty"`
	Finish    string `json:"finish_reason,omitempty"`
}

func (a *Link) modelPort(kind string) (int, bool) {
	if a.ModelPorts != nil {
		port, ok := a.ModelPorts[kind]

		return port, ok
	}

	for _, served := range a.serving() {
		if served.Kind == kind {
			return served.Port, true
		}
	}

	for _, known := range machine.Known {
		if known.Kind == kind {
			return known.Port, true
		}
	}

	return 0, false
}

func loopback(port int) *http.Client {
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	dialer := &net.Dialer{Timeout: 5 * time.Second}

	return &http.Client{
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, "tcp4", address)
			},
			MaxResponseHeaderBytes: 64 << 10,
			ResponseHeaderTimeout:  AnsweredWithin,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func (a *Link) model(ctx context.Context, raw json.RawMessage) (any, error) {
	wanted := Prompt{}
	if err := strictly(raw, &wanted); err != nil {
		return nil, err
	}

	port, ok := a.modelPort(wanted.Kind)
	if !ok || port < 1 || port > 65535 {
		return nil, ErrNoModelServer
	}

	if len(wanted.Messages) == 0 || len(wanted.Messages) > MostMessages {
		return nil, ErrPrompt
	}

	size := 0
	for _, message := range wanted.Messages {
		if message.Role != "system" && message.Role != "user" && message.Role != "assistant" {
			return nil, ErrRole
		}

		size += len(message.Content)
	}

	if size > MostPrompt || len(wanted.Model) > 200 {
		return nil, ErrPrompt
	}

	tokens := wanted.MaxTokens
	if tokens <= 0 {
		tokens = DefaultTokens
	}

	tokens = min(tokens, MostTokens)

	ctx, cancel := context.WithTimeout(ctx, AnsweredWithin)
	defer cancel()

	client := loopback(port)
	origin := "http://127.0.0.1:" + strconv.Itoa(port)

	named := wanted.Model
	if named == "" {
		first, err := firstModel(ctx, client, origin)
		if err != nil {
			return nil, err
		}

		named = first
	}

	body, err := json.Marshal(map[string]any{"model": named, "messages": wanted.Messages, "max_tokens": tokens, "stream": false})
	if err != nil {
		return nil, err
	}

	held := struct {
		Model   string `json:"model"`
		Choices []struct {
			Message      Message `json:"message"`
			FinishReason string  `json:"finish_reason"`
		} `json:"choices"`
	}{}

	if err := exchange(ctx, client, http.MethodPost, origin+chatFrom, body, &held); err != nil {
		return nil, err
	}

	if len(held.Choices) == 0 {
		return nil, fmt.Errorf("the %s server answered with no choices", wanted.Kind)
	}

	text, truncated := capped(held.Choices[0].Message.Content, MostAnswer)

	return Answered{Kind: wanted.Kind, Model: named, Text: text, Truncated: truncated, Finish: held.Choices[0].FinishReason}, nil
}

func firstModel(ctx context.Context, client *http.Client, origin string) (string, error) {
	held := struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}{}

	if err := exchange(ctx, client, http.MethodGet, origin+modelsListedFrom, nil, &held); err != nil {
		return "", err
	}

	for _, model := range held.Data {
		if model.ID != "" && !strings.Contains(strings.ToLower(model.ID), "embed") {
			return model.ID, nil
		}
	}

	return "", ErrNoModel
}

func exchange(ctx context.Context, client *http.Client, method, target string, body []byte, into any) error {
	var sent io.Reader
	if body != nil {
		sent = bytes.NewReader(body)
	}

	request, err := http.NewRequestWithContext(ctx, method, target, sent)
	if err != nil {
		return err
	}

	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrNoModelServer, err)
	}
	defer response.Body.Close()

	read, err := io.ReadAll(io.LimitReader(response.Body, MostModelReply+1))
	if err != nil {
		return err
	}

	if len(read) > MostModelReply {
		return fmt.Errorf("the model server answered with more than %d bytes", MostModelReply)
	}

	if response.StatusCode != http.StatusOK {
		said, _ := capped(string(read), 300)

		return fmt.Errorf("the model server answered %s: %s", response.Status, said)
	}

	if err := json.Unmarshal(read, into); err != nil {
		return fmt.Errorf("the model server answered with something that is not JSON: %w", err)
	}

	return nil
}

func capped(text string, most int) (string, bool) {
	if len(text) <= most {
		return text, false
	}

	cut := most
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}

	return text[:cut], true
}
