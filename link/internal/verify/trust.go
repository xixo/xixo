package verify

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/sigstore/sigstore-go/pkg/tuf"
	"github.com/theupdateframework/go-tuf/v2/metadata"
	"github.com/theupdateframework/go-tuf/v2/metadata/fetcher"
)

const Repository = "https://tuf-repo-cdn.sigstore.dev"

type recording struct {
	inner  fetcher.Fetcher
	mirror string
}

type replaying struct {
	mirror string
}

func Live(mirror, cache string) (root.TrustedMaterial, error) {
	return trusted(cache, &recording{inner: fetcher.NewDefaultFetcher(), mirror: mirror})
}

func Mirrored(mirror, cache string) (root.TrustedMaterial, error) {
	return trusted(cache, &replaying{mirror: mirror})
}

func trusted(cache string, fetching fetcher.Fetcher) (root.TrustedMaterial, error) {
	if err := os.MkdirAll(cache, 0o700); err != nil {
		return nil, err
	}

	options := tuf.DefaultOptions().
		WithRepositoryBaseURL(Repository).
		WithCachePath(cache).
		WithFetcher(fetching)

	client, err := tuf.New(options)
	if err != nil {
		return nil, fmt.Errorf("sigstore's TUF metadata does not check out: %w", err)
	}

	return root.GetTrustedRoot(client)
}

func mirrored(mirror, address string) (string, error) {
	parsed, err := url.Parse(address)
	if err != nil {
		return "", err
	}

	if parsed.Scheme+"://"+parsed.Host != Repository {
		return "", fmt.Errorf("%s is not in sigstore's TUF repository", address)
	}

	clean := path.Clean("/" + parsed.Path)
	if clean == "/" || strings.Contains(parsed.Path, "..") || strings.Contains(parsed.RawPath, "..") {
		return "", fmt.Errorf("%s names no file", address)
	}

	return filepath.Join(mirror, filepath.FromSlash(strings.TrimPrefix(clean, "/"))), nil
}

func (r *recording) DownloadFile(address string, most int64, timeout time.Duration) ([]byte, error) {
	held, err := r.inner.DownloadFile(address, most, timeout)
	if err != nil {
		return nil, err
	}

	if r.mirror == "" {
		return held, nil
	}

	if target, err := mirrored(r.mirror, address); err == nil {
		written(target, held)
	}

	return held, nil
}

func written(target string, held []byte) {
	if os.MkdirAll(filepath.Dir(target), 0o755) != nil {
		return
	}

	temporary, err := os.CreateTemp(filepath.Dir(target), ".mirror-*")
	if err != nil {
		return
	}

	defer os.Remove(temporary.Name())

	if _, err := temporary.Write(held); err != nil {
		temporary.Close()
		return
	}

	if temporary.Chmod(0o644) != nil || temporary.Close() != nil {
		return
	}

	os.Rename(temporary.Name(), target)
}

func (r *replaying) DownloadFile(address string, most int64, _ time.Duration) ([]byte, error) {
	target, err := mirrored(r.mirror, address)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(target)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, &metadata.ErrDownloadHTTP{StatusCode: 404, URL: address}
	}

	if err != nil {
		return nil, err
	}

	defer file.Close()

	held, err := io.ReadAll(io.LimitReader(file, most+1))
	if err != nil {
		return nil, err
	}

	if int64(len(held)) > most {
		return nil, &metadata.ErrDownloadLengthMismatch{Msg: fmt.Sprintf("%s is larger than %d bytes", address, most)}
	}

	return held, nil
}
