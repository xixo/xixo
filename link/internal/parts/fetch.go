package parts

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const (
	Fetching = 2 * time.Hour
	suffix   = ".download"
)

var (
	ErrMismatch = errors.New("the download did not match the SHA-256 xixo link was built with")
	ErrTooLarge = errors.New("the download is larger than xixo link accepts")
	ErrNoRoom   = errors.New("the disk has no room for the download")
)

func Fetch(ctx context.Context, client *http.Client, build Build, dir string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, Fetching)
	defer cancel()

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	path := filepath.Join(dir, build.SHA256[:16]+suffix)
	hashed := sha256.New()
	have := int64(0)

	if opened, err := os.Open(path); err == nil {
		have, err = io.Copy(hashed, opened)
		opened.Close()

		if err != nil {
			os.Remove(path)
			have = 0
			hashed = sha256.New()
		}
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, build.URL, nil)
	if err != nil {
		return "", err
	}

	if have > 0 {
		request.Header.Set("Range", "bytes="+strconv.FormatInt(have, 10)+"-")
	}

	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	expected := response.ContentLength
	if expected < 0 {
		expected = MostBuild / 2
	}

	if err := room(dir, expected*3); err != nil {
		return "", err
	}

	flags := os.O_WRONLY | os.O_CREATE | os.O_APPEND

	switch {
	case have > 0 && response.StatusCode == http.StatusPartialContent:
	case response.StatusCode == http.StatusOK:
		flags = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
		hashed = sha256.New()
		have = 0
	default:
		return "", fmt.Errorf("%s answered %s", build.URL, response.Status)
	}

	opened, err := os.OpenFile(path, flags, 0o644)
	if err != nil {
		return "", err
	}

	copied, err := io.Copy(io.MultiWriter(opened, hashed), io.LimitReader(response.Body, MostBuild-have+1))
	if closed := opened.Close(); err == nil {
		err = closed
	}

	if err != nil {
		return "", err
	}

	if have+copied > MostBuild {
		os.Remove(path)

		return "", ErrTooLarge
	}

	if hex.EncodeToString(hashed.Sum(nil)) != build.SHA256 {
		os.Remove(path)

		return "", ErrMismatch
	}

	return path, nil
}
