package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/verify"
)

const (
	FloorFile = "serial"
	TrustDir  = "trust"
)

var (
	Signer = verify.Signer{Repository: "xixo/xixo", Workflows: []string{"ci.yml", "release.yml"}}

	ErrUnsignedOffer = errors.New("xixo offered a build without a signed release")
	ErrOlderRelease  = errors.New("the release is older than one this machine already accepted")
	ErrNotInRelease  = errors.New("the build xixo offered is not the one the signed release lists")
)

type Vouch struct {
	Xixo     string
	Client   *http.Client
	Floor    string
	Trust    string
	Unsigned bool
	Verified func(bundle, raw []byte) (release.Release, error)
}

func (v *Vouch) verified(bundle, raw []byte) (release.Release, error) {
	if v.Verified != nil {
		return v.Verified(bundle, raw)
	}

	trusted, err := verify.Live("", v.Trust)
	if err != nil {
		return release.Release{}, err
	}

	held, _, err := (&verify.Checker{Trusted: trusted}).Release(bundle, raw, Signer)

	return held, err
}

func (v *Vouch) Release(ctx context.Context, target Target, goos, goarch string) (release.Release, error) {
	if v.Unsigned {
		return release.Release{}, nil
	}

	if target.Release == "" {
		return release.Release{}, ErrUnsignedOffer
	}

	raw, err := v.fetched(ctx, release.File)
	if err != nil {
		return release.Release{}, err
	}

	if release.Sum(raw) != target.Release {
		return release.Release{}, fmt.Errorf("%w: xixo served a release.json other than the one it named", verify.ErrUnsigned)
	}

	bundle, err := v.fetched(ctx, release.Bundle)
	if err != nil {
		return release.Release{}, err
	}

	held, err := v.verified(bundle, raw)
	if err != nil {
		return release.Release{}, err
	}

	if floor := v.floor(); held.Serial < floor {
		return release.Release{}, fmt.Errorf("%w: it is serial %d, and this machine accepted %d", ErrOlderRelease, held.Serial, floor)
	}

	build, found := held.Build(goos, goarch)
	if !found || build.SHA256 != target.SHA256 || held.Version != target.Version {
		return release.Release{}, fmt.Errorf("%w: %s %s for %s/%s", ErrNotInRelease, target.Version, target.SHA256, goos, goarch)
	}

	if target.MacReader != "" {
		reader, found := held.Reader()
		if !found || reader.SHA256 != target.MacReader {
			return release.Release{}, fmt.Errorf("%w: the mac reader %s", ErrNotInRelease, target.MacReader)
		}
	}

	return held, nil
}

func (v *Vouch) Accept(held release.Release) error {
	if v.Unsigned || held.Serial <= v.floor() {
		return nil
	}

	return Write(v.Floor, held.Serial, 0o644)
}

func (v *Vouch) floor() int64 {
	raw, err := os.ReadFile(v.Floor)
	if err != nil {
		return 0
	}

	held, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return 0
	}

	return held
}

func (v *Vouch) fetched(ctx context.Context, file string) ([]byte, error) {
	address := Address(v.Xixo, file)
	if !strings.HasPrefix(address, "https://") && !strings.HasPrefix(address, "http://") {
		return nil, fmt.Errorf("xixo link downloads only over http or https, not from %s", address)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}

	response, err := v.Client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("xixo answered %s with %s", file, response.Status)
	}

	raw, err := io.ReadAll(io.LimitReader(response.Body, release.MostFile+1))
	if err != nil {
		return nil, err
	}

	if len(raw) > release.MostFile {
		return nil, fmt.Errorf("xixo served a %s larger than %d bytes", file, release.MostFile)
	}

	return raw, nil
}
