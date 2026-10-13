package machine

import (
	"encoding/binary"
	"strings"
	"testing"
)

func TestHealthReadsTheKernelOnMacOS(t *testing.T) {
	held := New().Health(nil)

	if held.Uptime <= 0 {
		t.Errorf("uptime %v", held.Uptime)
	}

	if held.Load[0] <= 0 && held.Load[1] <= 0 && held.Load[2] <= 0 {
		t.Errorf("load %v", held.Load)
	}

	if held.Memory.Total == 0 || held.Memory.Available == 0 || held.Memory.Available > held.Memory.Total {
		t.Errorf("memory %+v", held.Memory)
	}

	if len(held.Disks) != 1 || held.Disks[0].Total == 0 {
		t.Errorf("disks %+v", held.Disks)
	}
}

func TestLoadsScalesTheKernelsFixedPoint(t *testing.T) {
	raw := make([]byte, 24)
	binary.LittleEndian.PutUint32(raw[0:], 2048)
	binary.LittleEndian.PutUint32(raw[4:], 1024)
	binary.LittleEndian.PutUint32(raw[8:], 512)
	binary.LittleEndian.PutUint64(raw[16:], 2048)

	held := loads(raw)
	if held[0] != 1 || held[1] != 0.5 || held[2] != 0.25 {
		t.Fatalf("load %v", held)
	}

	if short := loads(raw[:12]); short[0] != 0 {
		t.Fatalf("a short answer gave %v", short)
	}
}

func TestSystemAndModelOnMacOS(t *testing.T) {
	if got := system(); !strings.HasPrefix(got, "macOS ") {
		t.Errorf("system %q", got)
	}

	if model() == "" {
		t.Error("no model")
	}
}

func TestAMacNamesItsModelAndKind(t *testing.T) {
	raw := []byte(`  "model" = <"Mac14,6">` + "\n" + `  "product-name" = <"MacBook Pro (16-inch, 2023)">`)

	if got := productNameIn(raw); got != "MacBook Pro (16-inch, 2023)" {
		t.Fatalf("product name = %q", got)
	}

	cases := map[string]string{
		"MacBook Pro (16-inch, 2023)": "laptop",
		"MacBook Air (M2, 2022)":      "laptop",
		"iMac (24-inch, M3, 2023)":    "all-in-one",
		"Mac mini (2023)":             "desktop",
		"Mac Studio (2023)":           "desktop",
	}

	for named, want := range cases {
		if got := macKind(named, false); got != want {
			t.Errorf("macKind(%q) = %q, want %q", named, got, want)
		}
	}

	if got := macKind("Mac14,6", true); got != "laptop" {
		t.Errorf("a bare identifier falls back to the battery, got %q", got)
	}

	if got := macKind("", true); got != "laptop" {
		t.Errorf("an unnamed Mac with a battery reads as a laptop, got %q", got)
	}
}
