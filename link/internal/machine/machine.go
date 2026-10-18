package machine

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/xixo/xixo/link/internal/parts"
	"golang.org/x/sys/unix"
)

type Memory struct {
	Total     uint64 `json:"total"`
	Available uint64 `json:"available"`
}

type Disk struct {
	Path  string `json:"path"`
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

type Health struct {
	Uptime   float64        `json:"uptime"`
	Load     []float64      `json:"load"`
	Memory   Memory         `json:"memory"`
	Disks    []Disk         `json:"disks"`
	Parts    []parts.Status `json:"parts"`
	Warnings []string       `json:"warnings"`
}

type Service struct {
	Kind string `json:"kind"`
	Port int    `json:"port"`
}

type Hello struct {
	Version  string   `json:"version"`
	OS       string   `json:"os"`
	Arch     string   `json:"arch"`
	Hostname string   `json:"hostname"`
	Folders  []string `json:"folders"`
	Writable []string `json:"writable"`
	Details  About    `json:"details"`
	Lend     bool     `json:"lend"`
	Warnings []string `json:"warnings"`
}

var Known = []Service{
	{Kind: "ollama", Port: 11434},
	{Kind: "lmstudio", Port: 1234},
}

type Machine struct {
	Proc  string
	Probe func(ctx context.Context, port int) bool
}

func New() *Machine {
	return &Machine{Proc: procRoot, Probe: listening}
}

func (m *Machine) Hello(ctx context.Context, version string, folders, readers []string) Hello {
	hostname, _ := os.Hostname()

	return Hello{
		Version:  version,
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		Hostname: hostname,
		Folders:  folders,
		Details:  m.About(ctx, version, folders, readers),
	}
}

func (m *Machine) Services(ctx context.Context) []Service {
	found := []Service{}

	for _, known := range Known {
		if m.Probe(ctx, known.Port) {
			found = append(found, Service{Kind: known.Kind, Port: known.Port})
		}
	}

	return found
}

func (m *Machine) Health(folders []string) Health {
	held := Health{Load: []float64{0, 0, 0}, Disks: []Disk{}, Parts: []parts.Status{}, Warnings: []string{}}

	if m.Proc == "" {
		native(&held)
	} else {
		m.fromProc(&held)
	}

	for _, path := range append([]string{"/"}, folders...) {
		var stat unix.Statfs_t

		if unix.Statfs(path, &stat) != nil {
			continue
		}

		size := uint64(stat.Bsize)
		held.Disks = append(held.Disks, Disk{Path: path, Total: uint64(stat.Blocks) * size, Free: uint64(stat.Bavail) * size})
	}

	return held
}

func (m *Machine) fromProc(held *Health) {
	if raw, err := os.ReadFile(m.Proc + "/uptime"); err == nil {
		if fields := strings.Fields(string(raw)); len(fields) > 0 {
			held.Uptime, _ = strconv.ParseFloat(fields[0], 64)
		}
	}

	if raw, err := os.ReadFile(m.Proc + "/loadavg"); err == nil {
		fields := strings.Fields(string(raw))

		for index := 0; index < 3 && index < len(fields); index++ {
			held.Load[index], _ = strconv.ParseFloat(fields[index], 64)
		}
	}

	if raw, err := os.ReadFile(m.Proc + "/meminfo"); err == nil {
		held.Memory = memory(raw)
	}
}

func memory(raw []byte) Memory {
	held := Memory{}
	scanner := bufio.NewScanner(bytes.NewReader(raw))

	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}

		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}

		switch fields[0] {
		case "MemTotal:":
			held.Total = value * 1024
		case "MemAvailable:":
			held.Available = value * 1024
		}
	}

	return held
}

func listening(ctx context.Context, port int) bool {
	dialer := net.Dialer{Timeout: time.Second}

	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return false
	}

	conn.Close()

	return true
}
