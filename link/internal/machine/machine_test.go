package machine

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestHealthReadsProc(t *testing.T) {
	proc := t.TempDir()

	written := map[string]string{
		"uptime":  "12345.67 999.00\n",
		"loadavg": "0.50 0.25 0.10 1/200 4242\n",
		"meminfo": "MemTotal:        2048 kB\nMemFree:          512 kB\nMemAvailable:    1024 kB\n",
	}

	for name, body := range written {
		if err := os.WriteFile(filepath.Join(proc, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	held := (&Machine{Proc: proc}).Health([]string{proc, filepath.Join(proc, "missing")})

	if held.Uptime != 12345.67 {
		t.Errorf("uptime %v", held.Uptime)
	}

	if held.Load[0] != 0.5 || held.Load[1] != 0.25 || held.Load[2] != 0.1 {
		t.Errorf("load %v", held.Load)
	}

	if held.Memory.Total != 2048*1024 || held.Memory.Available != 1024*1024 {
		t.Errorf("memory %+v", held.Memory)
	}

	if len(held.Disks) != 2 || held.Disks[0].Path != "/" || held.Disks[1].Path != proc || held.Disks[1].Total == 0 {
		t.Errorf("disks %+v", held.Disks)
	}
}

func TestHealthWithoutProc(t *testing.T) {
	held := (&Machine{Proc: filepath.Join(t.TempDir(), "none")}).Health(nil)

	if len(held.Load) != 3 || held.Disks == nil {
		t.Fatalf("health %+v", held)
	}
}

func TestServicesNameTheTailnetAddress(t *testing.T) {
	asked := 0
	held := &Machine{
		Probe: func(_ context.Context, port int) bool { return port == 11434 },
		Tailnet: func(context.Context) string {
			asked++

			return "100.64.0.9"
		},
	}

	hello := held.Hello(context.Background(), "1.2.3", []string{"/srv"})

	if len(hello.Services) != 1 || hello.Services[0] != (Service{Kind: "ollama", Port: 11434, Address: "100.64.0.9"}) {
		t.Fatalf("services %+v", hello.Services)
	}

	if asked != 1 || hello.Version != "1.2.3" || hello.Folders[0] != "/srv" || hello.OS == "" || hello.Arch == "" {
		t.Fatalf("hello %+v", hello)
	}

	none := &Machine{Probe: func(context.Context, int) bool { return false }, Tailnet: func(context.Context) string { return "x" }}
	if got := none.Services(context.Background()); got == nil || len(got) != 0 {
		t.Fatalf("services %+v", got)
	}
}
