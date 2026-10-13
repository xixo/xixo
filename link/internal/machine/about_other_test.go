//go:build !darwin

package machine

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSystemAndModelReadTheFilesLinuxKeeps(t *testing.T) {
	dir := t.TempDir()
	release := filepath.Join(dir, "os-release")
	product := filepath.Join(dir, "product_name")
	os.WriteFile(release, []byte("PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\n"), 0o644)
	os.WriteFile(product, []byte("ThinkCentre M75q\n"), 0o644)

	beforeReleases, beforeProduct := osReleases, productName
	osReleases, productName = []string{filepath.Join(dir, "missing"), release}, product
	t.Cleanup(func() { osReleases, productName = beforeReleases, beforeProduct })

	if got := system(); got != "Debian GNU/Linux 13 (trixie)" {
		t.Fatalf("system %q", got)
	}

	if got := model(); got != "ThinkCentre M75q" {
		t.Fatalf("model %q", got)
	}

	os.WriteFile(product, []byte("To Be Filled By O.E.M.\n"), 0o644)
	if got := model(); got != "" {
		t.Fatalf("placeholder model %q", got)
	}

	osReleases = []string{filepath.Join(dir, "missing")}
	if got := system(); got != "Linux" {
		t.Fatalf("fallback %q", got)
	}
}

func TestTheChassisNamesWhatKindOfMachineItIs(t *testing.T) {
	cases := []struct {
		chassis string
		battery bool
		want    string
	}{
		{"10", false, "laptop"},
		{"3", false, "desktop"},
		{"13", false, "all-in-one"},
		{"23", false, "server"},
		{"1", true, "laptop"},
		{"", false, "server"},
	}

	for _, held := range cases {
		if got := chassisKind(held.chassis, held.battery); got != held.want {
			t.Errorf("chassisKind(%q, %v) = %q, want %q", held.chassis, held.battery, got, held.want)
		}
	}
}
