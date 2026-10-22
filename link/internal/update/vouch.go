package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"

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
	Running  int64
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

	return (&verify.Checker{Trusted: trusted}).Release(bundle, raw, Signer)
}

func (v *Vouch) Release(ctx context.Context, target Target, goos, goarch string) (release.Release, error) {
	if v == nil {
		return release.Release{}, ErrUnsignedOffer
	}

	if v.Unsigned {
		return release.Release{}, nil
	}

	if target.Release == "" {
		return release.Release{}, ErrUnsignedOffer
	}

	floor, err := v.floor()
	if err != nil {
		return release.Release{}, err
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

	if held.Serial < floor {
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
	if v == nil || v.Unsigned {
		return nil
	}

	return Raise(v.Floor, held.Serial)
}

func (v *Vouch) floor() (int64, error) {
	held, err := Floor(v.Floor)
	if err != nil {
		return 0, err
	}

	return max(held, v.Running), nil
}

func Floor(path string) (int64, error) {
	var held int64
	if err := Read(path, &held); err != nil && !missing(err) {
		return 0, fmt.Errorf("the serial this machine accepted cannot be read, so it installs nothing: %w", err)
	}

	return held, nil
}

func Raise(path string, serial int64) error {
	held, err := Floor(path)
	if err != nil || serial <= held {
		return err
	}

	return Write(path, serial, 0o644)
}

func FloorFor(releases string) string {
	return filepath.Join(filepath.Dir(releases), FloorFile)
}

func (v *Vouch) fetched(ctx context.Context, file string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, Fetching)
	defer cancel()

	response, err := get(ctx, v.Client, Address(v.Xixo, file))
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(response.Body, release.MostFile+1))
	if err != nil {
		return nil, err
	}

	if len(raw) > release.MostFile {
		return nil, fmt.Errorf("xixo served a %s larger than %d bytes", file, release.MostFile)
	}

	return raw, nil
}
