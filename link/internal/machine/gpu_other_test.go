//go:build !darwin

package machine

import (
	"os"
	"path/filepath"
	"testing"
)

func fakePCI(t *testing.T, devices map[string]map[string]string, drivers map[string]string) pciRoots {
	t.Helper()
	root := t.TempDir()
	held := pciRoots{
		Devices:       filepath.Join(root, "devices"),
		NVIDIAGPUs:    filepath.Join(root, "nvidia", "gpus"),
		NVIDIAVersion: filepath.Join(root, "nvidia", "version"),
		SMI:           func() []byte { return nil },
	}

	for address, files := range devices {
		dir := filepath.Join(held.Devices, address)
		os.MkdirAll(dir, 0o755)

		for name, value := range files {
			os.WriteFile(filepath.Join(dir, name), []byte(value+"\n"), 0o644)
		}

		if driver := drivers[address]; driver != "" {
			os.MkdirAll(filepath.Join(root, "drivers", driver), 0o755)
			os.Symlink(filepath.Join(root, "drivers", driver), filepath.Join(dir, "driver"))
		}
	}

	return held
}

func TestGPUsReadTheNVIDIADriverItsModelAndItsMemory(t *testing.T) {
	held := fakePCI(t, map[string]map[string]string{
		"0000:01:00.0": {"class": "0x030000", "vendor": "0x10de", "device": "0x1b81"},
		"0000:00:1f.3": {"class": "0x040300", "vendor": "0x8086"},
	}, map[string]string{"0000:01:00.0": "nvidia"})
	os.MkdirAll(filepath.Join(held.NVIDIAGPUs, "0000:01:00.0"), 0o755)
	os.WriteFile(filepath.Join(held.NVIDIAGPUs, "0000:01:00.0", "information"), []byte("Model: \t\t NVIDIA GeForce GTX 1070\nIRQ:   156\n"), 0o644)
	os.WriteFile(held.NVIDIAVersion, []byte("580.178.04\n"), 0o644)
	held.SMI = func() []byte { return []byte("00000000:01:00.0, NVIDIA GeForce GTX 1070, 8192\n") }

	got := held.gpus()
	want := GPU{Maker: MakerNVIDIA, Model: "NVIDIA GeForce GTX 1070", Memory: 8192 << 20, Driver: "580.178.04"}

	if len(got) != 1 || got[0] != want {
		t.Fatalf("gpus %+v", got)
	}
}

func TestAGPUWithoutADriverSaysSo(t *testing.T) {
	held := fakePCI(t, map[string]map[string]string{
		"0000:01:00.0": {"class": "0x030000", "vendor": "0x10de", "device": "0x1b81"},
		"0000:02:00.0": {"class": "0x030200", "vendor": "0x1002", "product_name": "Radeon RX 7900 XTX", "mem_info_vram_total": "25753026560"},
		"0000:03:00.0": {"class": "0x030000", "vendor": "0x10de"},
	}, map[string]string{"0000:02:00.0": "amdgpu", "0000:03:00.0": "nouveau"})

	got := held.gpus()
	want := []GPU{
		{Maker: MakerNVIDIA},
		{Maker: MakerAMD, Model: "Radeon RX 7900 XTX", Memory: 25753026560, Driver: "amdgpu"},
		{Maker: MakerNVIDIA, Driver: "nouveau"},
	}

	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("gpus %+v", got)
	}
}

func TestNoPCIBusMeansNoGPUs(t *testing.T) {
	held := pciRoots{Devices: filepath.Join(t.TempDir(), "none")}

	if got := held.gpus(); got == nil || len(got) != 0 {
		t.Fatalf("gpus %+v", got)
	}
}
