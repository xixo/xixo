package registry

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

func sha(raw []byte) string {
	sum := sha256.Sum256(raw)

	return "sha256:" + hex.EncodeToString(sum[:])
}

func (c *Client) token(host, name string) string {
	c.lock.Lock()
	defer c.lock.Unlock()

	return c.tokens[host+"/"+name]
}

func challenge(header string) map[string]string {
	held := map[string]string{}
	scheme, rest, _ := strings.Cut(header, " ")
	if !strings.EqualFold(scheme, "Bearer") {
		return held
	}

	for _, part := range strings.Split(rest, ",") {
		key, value, found := strings.Cut(strings.TrimSpace(part), "=")
		if found {
			held[strings.ToLower(key)] = strings.Trim(value, `"`)
		}
	}

	return held
}

func (c *Client) authorize(ctx context.Context, host, name, header string) error {
	asked := challenge(header)
	realm, err := url.Parse(asked["realm"])
	if err != nil || realm.Scheme != "https" && !strings.HasPrefix(c.base(host), "http://") {
		return fmt.Errorf("%s asked for a sign-in at %q", host, asked["realm"])
	}

	query := realm.Query()
	if asked["service"] != "" {
		query.Set("service", asked["service"])
	}

	query.Set("scope", "repository:"+name+":pull")
	realm.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, realm.String(), nil)
	if err != nil {
		return err
	}

	response, err := c.client().Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s refused an anonymous token for %s: %d", host, name, response.StatusCode)
	}

	held := struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}{}

	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&held); err != nil {
		return err
	}

	token := held.Token
	if token == "" {
		token = held.AccessToken
	}

	c.lock.Lock()
	defer c.lock.Unlock()

	if c.tokens == nil {
		c.tokens = map[string]string{}
	}

	c.tokens[host+"/"+name] = token

	return nil
}
