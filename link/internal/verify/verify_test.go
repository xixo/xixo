package verify

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/sigstore/sigstore-go/pkg/root"
)

const built = "sha256:714a1360649077ded84650e6bd5369e5ccca0531de47192dc4e05d1fd6d6ef1a"

var xixo = Signer{Repository: "xixo/xixo", Workflows: []string{"ci.yml", "release.yml"}}

func checker(t *testing.T) *Checker {
	t.Helper()
	trusted, err := root.NewTrustedRootFromPath("testdata/trusted_root.json")
	if err != nil {
		t.Fatal(err)
	}

	return &Checker{Trusted: trusted}
}

func bundled(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile("testdata/xixo.sigstore.json")
	if err != nil {
		t.Fatal(err)
	}

	return raw
}

func TestAnImageCIBuiltOnMainChecksOut(t *testing.T) {
	signed, err := checker(t).Check(bundled(t), built, xixo)
	if err != nil {
		t.Fatal(err)
	}

	if signed.Workflow != "ci.yml" || signed.Ref != Branch || len(signed.Commit) != 40 || signed.Repository != "xixo/xixo" {
		t.Fatalf("signed %+v", signed)
	}
}

func TestAnyOtherDigestIsRefused(t *testing.T) {
	other := "sha256:" + strings.Repeat("0", 64)
	if _, err := checker(t).Check(bundled(t), other, xixo); !errors.Is(err, ErrUnsigned) {
		t.Fatalf("err %v", err)
	}
}

func TestAnotherRepositoryOrWorkflowIsRefused(t *testing.T) {
	for _, signer := range []Signer{
		{Repository: "masksrb/masks", Workflows: []string{"ci.yml"}},
		{Repository: "xixo/xixo", Workflows: []string{"release.yml"}},
		{Repository: "xixo/xixo-fork", Workflows: []string{"ci.yml"}},
	} {
		if _, err := checker(t).Check(bundled(t), built, signer); !errors.Is(err, ErrUnsigned) {
			t.Fatalf("%+v: err %v", signer, err)
		}
	}
}

func TestATamperedBundleIsRefused(t *testing.T) {
	raw := bundled(t)
	at := strings.Index(string(raw), `"signature":"`) + len(`"signature":"`)
	tampered := append([]byte{}, raw...)
	if tampered[at] == 'A' {
		tampered[at] = 'B'
	} else {
		tampered[at] = 'A'
	}

	if _, err := checker(t).Check(tampered, built, xixo); !errors.Is(err, ErrUnsigned) {
		t.Fatalf("err %v", err)
	}

	if _, err := checker(t).Check([]byte("{}"), built, xixo); !errors.Is(err, ErrUnsigned) {
		t.Fatalf("err %v", err)
	}
}

func TestASignerMustNameAFileAndARepository(t *testing.T) {
	for _, signer := range []Signer{
		{Repository: "xixo", Workflows: []string{"ci.yml"}},
		{Repository: "xixo/xixo", Workflows: []string{"../ci.yml"}},
		{Repository: "xixo/xixo"},
	} {
		if _, err := checker(t).Check(bundled(t), built, signer); err == nil {
			t.Fatalf("%+v was accepted", signer)
		}
	}
}
