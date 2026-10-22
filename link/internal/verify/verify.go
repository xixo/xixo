package verify

import (
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/sigstore/sigstore-go/pkg/bundle"
	"github.com/sigstore/sigstore-go/pkg/root"
	sigstore "github.com/sigstore/sigstore-go/pkg/verify"
	"github.com/xixo/xixo/link/internal/release"
)

const (
	Issuer     = "https://token.actions.githubusercontent.com"
	Provenance = "https://slsa.dev/provenance/v1"
	Hosted     = "github-hosted"
	Branch     = "refs/heads/main"
	MostBundle = 1 << 20
)

var (
	ErrUnsigned = errors.New("no attestation checks out for this build")
	digestShape = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	repoShape   = regexp.MustCompile(`^[a-z0-9-]+/[a-z0-9._-]+$`)
	fileShape   = regexp.MustCompile(`^[a-z0-9-]+\.yml$`)
)

type Signer struct {
	Repository string
	Workflows  []string
}

type Signed struct {
	Repository string
	Workflow   string
	Commit     string
	Ref        string
}

type Checker struct {
	Trusted root.TrustedMaterial
}

func (s Signer) Valid() error {
	if !repoShape.MatchString(s.Repository) || len(s.Workflows) == 0 {
		return fmt.Errorf("signer %q names no repository and workflow", s.Repository)
	}

	for _, workflow := range s.Workflows {
		if !fileShape.MatchString(workflow) {
			return fmt.Errorf("signer %q names the workflow %q, which is not a file name", s.Repository, workflow)
		}
	}

	return nil
}

func (s Signer) san() string {
	quoted := make([]string, len(s.Workflows))
	for i, workflow := range s.Workflows {
		quoted[i] = regexp.QuoteMeta(workflow)
	}

	return "^" + regexp.QuoteMeta("https://github.com/"+s.Repository+"/.github/workflows/") +
		"(" + strings.Join(quoted, "|") + ")" + regexp.QuoteMeta("@"+Branch) + "$"
}

func (c *Checker) Check(raw []byte, digest string, signer Signer) (Signed, error) {
	if err := signer.Valid(); err != nil {
		return Signed{}, err
	}

	if !digestShape.MatchString(digest) {
		return Signed{}, fmt.Errorf("%q is not a sha256 digest", digest)
	}

	if len(raw) > MostBundle {
		return Signed{}, fmt.Errorf("%w: the bundle is larger than %d bytes", ErrUnsigned, MostBundle)
	}

	held := &bundle.Bundle{}
	if err := held.UnmarshalJSON(raw); err != nil {
		return Signed{}, fmt.Errorf("%w: %v", ErrUnsigned, err)
	}

	verifier, err := sigstore.NewVerifier(c.Trusted,
		sigstore.WithSignedCertificateTimestamps(1),
		sigstore.WithTransparencyLog(1),
		sigstore.WithObserverTimestamps(1))
	if err != nil {
		return Signed{}, err
	}

	identity, err := sigstore.NewShortCertificateIdentity(Issuer, "", "", signer.san())
	if err != nil {
		return Signed{}, err
	}

	sum, _ := hex.DecodeString(strings.TrimPrefix(digest, "sha256:"))

	result, err := verifier.Verify(held, sigstore.NewPolicy(
		sigstore.WithArtifactDigest("sha256", sum),
		sigstore.WithCertificateIdentity(identity)))
	if err != nil {
		return Signed{}, fmt.Errorf("%w: %v", ErrUnsigned, err)
	}

	return signed(result, signer)
}

func signed(result *sigstore.VerificationResult, signer Signer) (Signed, error) {
	if result.Statement == nil || result.Statement.GetPredicateType() != Provenance {
		return Signed{}, fmt.Errorf("%w: the attestation is not SLSA provenance v1", ErrUnsigned)
	}

	if result.Signature == nil || result.Signature.Certificate == nil {
		return Signed{}, fmt.Errorf("%w: the attestation carries no certificate", ErrUnsigned)
	}

	held := result.Signature.Certificate
	source := "https://github.com/" + signer.Repository

	switch {
	case held.Issuer != Issuer:
		return Signed{}, fmt.Errorf("%w: issued by %q", ErrUnsigned, held.Issuer)
	case held.SourceRepositoryURI != source:
		return Signed{}, fmt.Errorf("%w: built from %q, not %s", ErrUnsigned, held.SourceRepositoryURI, source)
	case held.SourceRepositoryRef != Branch:
		return Signed{}, fmt.Errorf("%w: built from %q, not %s", ErrUnsigned, held.SourceRepositoryRef, Branch)
	case held.RunnerEnvironment != Hosted:
		return Signed{}, fmt.Errorf("%w: built on a %q runner, not a GitHub-hosted one", ErrUnsigned, held.RunnerEnvironment)
	}

	workflow := strings.TrimPrefix(held.BuildSignerURI, source+"/.github/workflows/")
	workflow, _, _ = strings.Cut(workflow, "@")

	return Signed{Repository: signer.Repository, Workflow: workflow, Commit: held.SourceRepositoryDigest, Ref: held.SourceRepositoryRef}, nil
}

func (c *Checker) Release(bundle, raw []byte, signer Signer) (release.Release, error) {
	signed, err := c.Check(bundle, "sha256:"+release.Sum(raw), signer)
	if err != nil {
		return release.Release{}, err
	}

	held, err := release.Parse(raw)
	if err != nil {
		return release.Release{}, fmt.Errorf("%w: %v", ErrUnsigned, err)
	}

	if held.Revision != signed.Commit {
		return release.Release{}, fmt.Errorf("%w: the release names %s, and CI signed %s", ErrUnsigned, held.Revision, signed.Commit)
	}

	return held, nil
}
