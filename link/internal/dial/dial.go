package dial

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"time"
)

const (
	Connect  = 10 * time.Second
	Answered = 30 * time.Second
)

var ErrPlain = errors.New("plain http reaches only this machine")

type Guard struct {
	Hosts    string
	Resolver interface {
		LookupNetIP(ctx context.Context, network, host string) ([]netip.Addr, error)
	}
}

func Local(host string) bool {
	host = strings.TrimSuffix(strings.ToLower(host), ".")

	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}

	held, err := netip.ParseAddr(strings.Trim(host, "[]"))

	return err == nil && held.Unmap().IsLoopback()
}

func (g Guard) Addresses(ctx context.Context, host string) ([]netip.Addr, error) {
	bare := strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")

	if held, err := netip.ParseAddr(bare); err == nil {
		if !held.Unmap().IsLoopback() {
			return nil, fmt.Errorf("%w: %s is not a loopback address", ErrPlain, host)
		}

		return []netip.Addr{held}, nil
	}

	if !Local(bare) {
		return nil, fmt.Errorf("%w: %s is not a localhost name", ErrPlain, host)
	}

	if pinned := g.pinned(bare); len(pinned) > 0 {
		return pinned, nil
	}

	resolver := g.Resolver
	if resolver == nil {
		resolver = net.DefaultResolver
	}

	found, err := resolver.LookupNetIP(ctx, "ip", bare)
	if err != nil {
		return nil, err
	}

	if len(found) == 0 {
		return nil, fmt.Errorf("%w: %s resolves to nothing", ErrPlain, host)
	}

	for _, held := range found {
		if !held.Unmap().IsLoopback() {
			return nil, fmt.Errorf("%w: %s resolves to %s, which is not a loopback address, and %s does not name it", ErrPlain, host, held, g.hosts())
		}
	}

	return found, nil
}

func (g Guard) hosts() string {
	if g.Hosts == "" {
		return "/etc/hosts"
	}

	return g.Hosts
}

func (g Guard) pinned(host string) []netip.Addr {
	opened, err := os.Open(g.hosts())
	if err != nil {
		return nil
	}
	defer opened.Close()

	held := []netip.Addr{}
	lines := bufio.NewScanner(opened)

	for lines.Scan() {
		line, _, _ := strings.Cut(lines.Text(), "#")
		fields := strings.Fields(line)

		if len(fields) < 2 {
			continue
		}

		address, err := netip.ParseAddr(fields[0])
		if err != nil {
			continue
		}

		for _, name := range fields[1:] {
			if strings.EqualFold(strings.TrimSuffix(name, "."), host) {
				held = append(held, address)

				break
			}
		}
	}

	return held
}

func (g Guard) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}

	found, err := g.Addresses(ctx, host)
	if err != nil {
		return nil, err
	}

	dialer := &net.Dialer{Timeout: Connect}
	var last error

	for _, held := range found {
		conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(held.String(), port))
		if err == nil {
			return conn, nil
		}

		last = err
	}

	return nil, last
}

type split struct {
	plain  http.RoundTripper
	secure http.RoundTripper
}

func (s split) RoundTrip(request *http.Request) (*http.Response, error) {
	switch request.URL.Scheme {
	case "https", "wss":
		return s.secure.RoundTrip(request)
	case "http", "ws":
		return s.plain.RoundTrip(request)
	default:
		if request.Body != nil {
			request.Body.Close()
		}

		return nil, fmt.Errorf("xixo link speaks only http and https, not %q", request.URL.Scheme)
	}
}

func Transport(guard Guard) http.RoundTripper {
	secure := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: Connect, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   Connect,
		ResponseHeaderTimeout: Answered,
		ExpectContinueTimeout: time.Second,
		IdleConnTimeout:       90 * time.Second,
		MaxIdleConns:          16,
	}

	plain := &http.Transport{
		DialContext:           guard.DialContext,
		ResponseHeaderTimeout: Answered,
		IdleConnTimeout:       90 * time.Second,
		MaxIdleConns:          16,
	}

	return split{plain: plain, secure: secure}
}

var shared = Transport(Guard{})

func Client(timeout time.Duration) *http.Client {
	return &http.Client{Transport: shared, Timeout: timeout}
}

func Fetcher() *http.Client {
	return &http.Client{
		Transport:     shared,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}
