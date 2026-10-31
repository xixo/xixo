package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/xixo/xixo/link/internal/release"
	"github.com/xixo/xixo/link/internal/verify"
)

const (
	FloorFile = "serial"
	TrustDir  = "trust"
	MirrorDir = "mirror"
)

var (
	Signer = verify.Signer{Repository: "xixo/xixo", Workflows: []string{"ci.yml", "release.yml"}}

	ErrUnsignedOffer = errors.New("xixo offered a build without a signed release")
	ErrOlderRelease  = errors.New("the release is older than one this machine already accepted")
	ErrNotInRelease  = errors.New("the build xixo offered is not the one the signed release lists")
	ErrNoRelease     = errors.New("xixo serves no release.json, so there is nothing to install")
)

type Verified struct {
	release.Release
	ID     string
	Raw    []byte
	Bundle []byte
}

type Vouch struct {
	Xixo     string
	Client   *http.Client
	Floor    string
	Trust    string
	Mirror   string
	Offline  bool
	Running  int64
	Unsigned bool
	Verified func(bundle, raw []byte) (release.Release, error)
}

func (v *Vouch) verified(bundle, raw []byte) (release.Release, error) {
	if v.Verified != nil {
		return v.Verified(bundle, raw)
	}

	trusted, err := v.trusted()
	if err != nil {
		return release.Release{}, err
	}

	return (&verify.Checker{Trusted: trusted}).Release(bundle, raw, Signer)
}

func (v *Vouch) trusted() (root.TrustedMaterial, error) {
	if v.Offline {
		return verify.Mirrored(v.Mirror, v.Trust)
	}

	if v.Mirror != "" {
		os.RemoveAll(v.Mirror)
		os.RemoveAll(v.Trust)
	}

	return verify.Live(v.Mirror, v.Trust)
}

func (v *Vouch) Verify(raw, bundle []byte) (Verified, error) {
	if v == nil {
		return Verified{}, ErrUnsignedOffer
	}

	floor, err := v.floor()
	if err != nil {
		return Verified{}, err
	}

	var held release.Release

	if v.Unsigned {
		held, err = release.Parse(raw)
	} else {
		held, err = v.verified(bundle, raw)
	}

	if err != nil {
		return Verified{}, err
	}

	if held.Serial < floor {
		return Verified{}, fmt.Errorf("%w: it is serial %d, and this machine accepted %d", ErrOlderRelease, held.Serial, floor)
	}

	return Verified{Release: held, ID: release.ID(raw), Raw: raw, Bundle: bundle}, nil
}

func (v *Vouch) Served(ctx context.Context) (Verified, error) {
	if v == nil {
		return Verified{}, ErrUnsignedOffer
	}

	raw, err := v.fetched(ctx, release.File)
	if err != nil {
		if v.Unsigned && isNotFound(err) {
			return Verified{}, ErrNoRelease
		}

		return Verified{}, err
	}

	bundle, err := v.fetched(ctx, release.Bundle)
	if err != nil && !(v.Unsigned && isNotFound(err)) {
		return Verified{}, err
	}

	return v.Verify(raw, bundle)
}

func (v *Vouch) Release(ctx context.Context, target Target, goos, goarch string) (Verified, error) {
	if v == nil {
		return Verified{}, ErrUnsignedOffer
	}

	if target.Release == "" && !v.Unsigned {
		return Verified{}, ErrUnsignedOffer
	}

	held, err := v.Served(ctx)
	if err != nil {
		return Verified{}, err
	}

	if target.Release != "" && release.Sum(held.Raw) != target.Release {
		return Verified{}, fmt.Errorf("%w: xixo served a release.json other than the one it named", verify.ErrUnsigned)
	}

	build, found := held.Build(goos, goarch)
	if !found || build.SHA256 != target.SHA256 || held.Version != target.Version {
		return Verified{}, fmt.Errorf("%w: %s %s for %s/%s", ErrNotInRelease, target.Version, target.SHA256, goos, goarch)
	}

	if target.MacReader != "" {
		reader, found := held.Reader()
		if !found || reader.SHA256 != target.MacReader {
			return Verified{}, fmt.Errorf("%w: the mac reader %s", ErrNotInRelease, target.MacReader)
		}
	}

	return held, nil
}

func (v *Vouch) Accept(held release.Release) error {
	if v == nil {
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

type notFound struct{ file string }

func (n notFound) Error() string { return "xixo answered " + n.file + " with 404 Not Found" }

func isNotFound(err error) bool {
	var held notFound

	return errors.As(err, &held)
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
