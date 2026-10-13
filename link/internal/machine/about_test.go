package machine

import (
	"context"
	"net"
	"strings"
	"testing"
)

func TestAboutDescribesTheMachineAndItsFolders(t *testing.T) {
	folder := t.TempDir()
	held := &Machine{
		Proc:    t.TempDir(),
		Probe:   func(_ context.Context, port int) bool { return port == 11434 },
		Tailnet: func(context.Context) string { return "100.64.0.9" },
	}

	about := held.About(context.Background(), "1.2.3", []string{folder})

	if about.CPUs < 1 || about.Version != "1.2.3" || about.System == "" || about.User == "" {
		t.Fatalf("about %+v", about)
	}

	if len(about.Disks) != 1 || about.Disks[0].Path != folder || about.Disks[0].Total == 0 {
		t.Fatalf("disks %+v", about.Disks)
	}

	if len(about.Services) != 1 || about.Services[0].Kind != "ollama" || about.Services[0].Address != "100.64.0.9" {
		t.Fatalf("services %+v", about.Services)
	}

	if about.Addresses == nil {
		t.Fatal("addresses is nil")
	}
}

func TestAboutWithNoFoldersNamesTheRootDisk(t *testing.T) {
	about := (&Machine{Proc: t.TempDir(), Probe: func(context.Context, int) bool { return false }}).About(context.Background(), "dev", nil)

	if len(about.Disks) != 1 || about.Disks[0].Path != "/" {
		t.Fatalf("disks %+v", about.Disks)
	}
}

func TestUsableKeepsRoutableAddressesFourFirst(t *testing.T) {
	cidr := func(text string) net.Addr {
		ip, network, err := net.ParseCIDR(text)
		if err != nil {
			t.Fatal(err)
		}

		network.IP = ip

		return network
	}

	held := []net.Addr{
		cidr("127.0.0.1/8"), cidr("::1/128"), cidr("fe80::1/64"), cidr("fd7a:115c:a1e0::9/48"),
		cidr("192.168.1.39/24"), cidr("100.64.0.9/32"), cidr("169.254.1.1/16"),
	}

	if got := strings.Join(usable(held), ","); got != "192.168.1.39,100.64.0.9,fd7a:115c:a1e0::9" {
		t.Fatalf("usable %q", got)
	}

	many := []net.Addr{}
	for range 20 {
		many = append(many, cidr("10.0.0.1/8"))
	}

	if len(usable(many)) != mostAddresses {
		t.Fatalf("kept %d", len(usable(many)))
	}
}

func TestOSReleaseReadsThePrettyName(t *testing.T) {
	raw := []byte("NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n")
	if got := osRelease(raw); got != "Ubuntu 24.04.1 LTS" {
		t.Fatalf("pretty %q", got)
	}

	if got := osRelease([]byte("NAME=Alpine\nID=alpine\n")); got != "Alpine" {
		t.Fatalf("name %q", got)
	}

	if got := osRelease([]byte("garbage")); got != "" {
		t.Fatalf("garbage %q", got)
	}
}

func TestClippedBoundsText(t *testing.T) {
	if got := clipped("  a \n b\t"); got != "a b" {
		t.Fatalf("clipped %q", got)
	}

	if got := clipped(strings.Repeat("x", 500)); len(got) != mostText {
		t.Fatalf("clipped to %d", len(got))
	}
}
