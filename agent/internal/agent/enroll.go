package agent

import (
	"context"
	"errors"
	"strings"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/agent/internal/state"
)

func Enroll(ctx context.Context, config *state.Config, held state.State, token, name string, options ...masks.Option) (*masks.Registration, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, errors.New("enrolling needs the token xixo made for this machine")
	}

	issuer, err := masks.Discover(ctx, config.Issuer, options...)
	if err != nil {
		return nil, err
	}

	key, _, err := held.Keys()
	if err != nil {
		return nil, err
	}

	previous, _ := held.Registration()

	registered, err := issuer.Register(ctx, masks.ClientMetadata{Name: name, JWKS: key.JWKS()}, token)
	if err != nil {
		return nil, err
	}

	if registered.TokenEndpointAuthMethod == "" {
		registered.TokenEndpointAuthMethod = masks.PrivateKeyJWT
	}

	if err := held.Keep(registered); err != nil {
		return nil, err
	}

	if previous != nil && previous.ClientID != "" && previous.ClientID != registered.ClientID {
		_ = issuer.DeleteRegistration(ctx, previous)
	}

	return registered, nil
}

func Client(ctx context.Context, config *state.Config, held state.State, options ...masks.Option) (*masks.Client, *masks.Key, error) {
	registered, err := held.Registration()
	if err != nil {
		return nil, nil, errors.New("this machine is not enrolled: run xixo-agent enroll first")
	}

	key, dpop, err := held.Keys()
	if err != nil {
		return nil, nil, err
	}

	issuer, err := masks.Discover(ctx, config.Issuer, options...)
	if err != nil {
		return nil, nil, err
	}

	return issuer.Client(registered, key, dpop), dpop, nil
}

func Tokens(client *masks.Client, config *state.Config) masks.TokenSource {
	return client.CredentialsSource(masks.TokenRequest{Scope: []string{state.Scope}, Resource: []string{config.Resource()}})
}
