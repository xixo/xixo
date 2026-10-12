package dial

import (
	"context"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

type resolver map[string][]netip.Addr

func (r resolver) LookupNetIP(_ context.Context, _, host string) ([]netip.Addr, error) {
	held, ok := r[host]
	if !ok {
		return nil, errors.New("no such host")
	}

	return held, nil
}

func addresses(raw ...string) []netip.Addr {
	held := []netip.Addr{}
	for _, one := range raw {
		held = append(held, netip.MustParseAddr(one))
	}

	return held
}

func TestPlainHTTPReachesOnlyThisMachine(t *testing.T) {
	hosts := filepath.Join(t.TempDir(), "hosts")
	os.WriteFile(hosts, []byte("127.0.0.1 localhost\n192.168.65.254 xixo.localhost masks.localhost # docker\n"), 0o644)

	guard := Guard{Hosts: hosts, Resolver: resolver{
		"loop.localhost":    addresses("127.0.0.1", "::1"),
		"spoofed.localhost": addresses("127.0.0.1", "203.0.113.9"),
		"example.com":       addresses("127.0.0.1"),
	}}

	cases := map[string]string{
		"127.0.0.1":         "127.0.0.1",
		"::1":               "::1",
		"[::1]":             "::1",
		"loop.localhost":    "127.0.0.1",
		"xixo.localhost":    "192.168.65.254",
		"MASKS.localhost.":  "192.168.65.254",
		"spoofed.localhost": "",
		"10.0.0.1":          "",
		"example.com":       "",
		"missing.localhost": "",
	}

	for host, want := range cases {
		found, err := guard.Addresses(context.Background(), host)

		switch {
		case want == "" && err == nil:
			t.Errorf("%s reached %v", host, found)
		case want != "" && (err != nil || found[0].String() != want):
			t.Errorf("%s gave %v %v, want %s", host, found, err, want)
		}
	}
}

func TestLocalNamesOnlyLoopbackHosts(t *testing.T) {
	for host, want := range map[string]bool{
		"localhost": true, "xixo.localhost": true, "127.0.0.1": true, "::1": true, "[::1]": true,
		"localhost.example": false, "100.64.0.2": false, "xixolocalhost": false,
	} {
		if Local(host) != want {
			t.Errorf("%s local %v", host, !want)
		}
	}
}
