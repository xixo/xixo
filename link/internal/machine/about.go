package machine

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"os"
	"os/user"
	"runtime"
	"strconv"
	"strings"
)

const (
	mostAddresses = 8
	mostGPUs      = 8
	mostText      = 80
)

type GPU struct {
	Maker  string `json:"maker"`
	Model  string `json:"model"`
	Memory uint64 `json:"memory"`
	Driver string `json:"driver"`
}

type About struct {
	User      string    `json:"user"`
	System    string    `json:"system"`
	Model     string    `json:"model"`
	Kind      string    `json:"kind"`
	Battery   bool      `json:"battery"`
	CPUs      int       `json:"cpus"`
	Memory    uint64    `json:"memory"`
	GPUs      []GPU     `json:"gpus"`
	Disks     []Disk    `json:"disks"`
	Addresses []string  `json:"addresses"`
	Version   string    `json:"version"`
	Readers   []string  `json:"readers"`
	Services  []Service `json:"services"`
}

func (m *Machine) About(ctx context.Context, version string, folders, readers []string) About {
	health := m.Health(folders)
	disks := []Disk{}

	for _, disk := range health.Disks {
		if disk.Path != "/" || len(folders) == 0 {
			disks = append(disks, disk)
		}
	}

	named := clipped(model())
	battery := hasBattery()

	if readers == nil {
		readers = []string{}
	}

	return About{
		User:      runsAs(),
		System:    clipped(system()),
		Model:     named,
		Kind:      kind(named, battery),
		Battery:   battery,
		CPUs:      runtime.NumCPU(),
		Memory:    health.Memory.Total,
		GPUs:      m.gpus(),
		Disks:     disks,
		Addresses: addresses(),
		Version:   clipped(version),
		Readers:   readers,
		Services:  m.Services(ctx),
	}
}

func (m *Machine) gpus() []GPU {
	found := []GPU{}

	for _, gpu := range m.GPUs() {
		gpu.Maker = clipped(gpu.Maker)
		gpu.Model = clipped(gpu.Model)
		gpu.Driver = clipped(gpu.Driver)
		found = append(found, gpu)

		if len(found) == mostGPUs {
			break
		}
	}

	return found
}

func runsAs() string {
	if held, err := user.Current(); err == nil && held.Username != "" {
		return clipped(held.Username)
	}

	return clipped(os.Getenv("USER"))
}

func addresses() []string {
	found := []string{}

	held, err := net.InterfaceAddrs()
	if err != nil {
		return found
	}

	return usable(held)
}

func usable(held []net.Addr) []string {
	four := []string{}
	six := []string{}

	for _, address := range held {
		network, ok := address.(*net.IPNet)
		if !ok {
			continue
		}

		ip := network.IP
		if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() {
			continue
		}

		if ip.To4() != nil {
			four = append(four, ip.String())
		} else {
			six = append(six, ip.String())
		}
	}

	found := append(four, six...)
	if len(found) > mostAddresses {
		found = found[:mostAddresses]
	}

	return found
}

func osRelease(raw []byte) string {
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	name := ""

	for scanner.Scan() {
		key, value, ok := strings.Cut(strings.TrimSpace(scanner.Text()), "=")
		if !ok {
			continue
		}

		if unquoted, err := strconv.Unquote(value); err == nil {
			value = unquoted
		} else {
			value = strings.Trim(value, `'"`)
		}

		switch key {
		case "PRETTY_NAME":
			return value
		case "NAME":
			name = value
		}
	}

	return name
}

func clipped(text string) string {
	text = strings.Join(strings.Fields(text), " ")
	if len(text) > mostText {
		text = text[:mostText]
	}

	return strings.ToValidUTF8(text, "")
}
