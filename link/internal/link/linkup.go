package link

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/state"
)

const mostLinkAnswer = 4096

func LinkUp(ctx context.Context, config *state.Config, held state.State, code string, options ...masks.Option) (string, error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return "", errors.New("linking up needs the code xixo showed for this machine")
	}

	client, _, err := Client(ctx, config, held, options...)
	if err != nil {
		return "", err
	}

	body := url.Values{"code": {code}}.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, config.Xixo+"/link", strings.NewReader(body))
	if err != nil {
		return "", err
	}

	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	response, err := client.HTTPClient(Tokens(client, config), config.Xixo).Do(request)
	if held := (&masks.Error{}); errors.As(err, &held) {
		return "", refused(err)
	}

	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	said, _ := io.ReadAll(io.LimitReader(response.Body, mostLinkAnswer))
	told := strings.TrimSpace(string(said))

	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("xixo did not link this machine up (%d): %s", response.StatusCode, told)
	}

	return told, nil
}
