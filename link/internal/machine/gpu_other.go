//go:build !darwin

package machine

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	MakerNVIDIA = "NVIDIA"
	MakerAMD    = "AMD"
	MakerIntel  = "Intel"
)

type pciRoots struct {
	Devices       string
	NVIDIAGPUs    string
	NVIDIAVersion string
	SMI           func() []byte
}

var pci = pciRoots{
	Devices:       "/sys/bus/pci/devices",
	NVIDIAGPUs:    "/proc/driver/nvidia/gpus",
	NVIDIAVersion: "/sys/module/nvidia/version",
	SMI:           nvidiaSMI,
}

var makers = map[string]string{"0x10de": MakerNVIDIA, "0x1002": MakerAMD, "0x8086": MakerIntel}

func (m *Machine) GPUs() []GPU {
	return pci.gpus()
}

func (p pciRoots) gpus() []GPU {
	entries, err := os.ReadDir(p.Devices)
	if err != nil {
		return []GPU{}
	}

	found := []GPU{}
	var smi []smiRow

	for _, entry := range entries {
		dir := filepath.Join(p.Devices, entry.Name())
		class := read(filepath.Join(dir, "class"))

		if !strings.HasPrefix(class, "0x0300") && !strings.HasPrefix(class, "0x0302") {
			continue
		}

		maker := makers[read(filepath.Join(dir, "vendor"))]
		if maker == "" {
			continue
		}

		gpu := GPU{Maker: maker, Driver: driverOf(dir)}

		switch {
		case maker == MakerNVIDIA && gpu.Driver == "nvidia":
			gpu.Model = p.nvidiaModel(entry.Name())
			gpu.Driver = read(p.NVIDIAVersion)

			if smi == nil {
				smi = smiRows(p.SMI())
			}

			for _, row := range smi {
				if strings.HasSuffix(strings.ToLower(row.bus), strings.ToLower(entry.Name()[len(entry.Name())-7:])) {
					gpu.Memory = row.memory

					if gpu.Model == "" {
						gpu.Model = row.model
					}
				}
			}
		case maker == MakerAMD:
			gpu.Model = read(filepath.Join(dir, "product_name"))
			gpu.Memory, _ = strconv.ParseUint(read(filepath.Join(dir, "mem_info_vram_total")), 10, 64)
		}

		found = append(found, gpu)
	}

	return found
}

func (p pciRoots) nvidiaModel(address string) string {
	raw, err := os.ReadFile(filepath.Join(p.NVIDIAGPUs, address, "information"))
	if err != nil {
		return ""
	}

	scanner := bufio.NewScanner(bytes.NewReader(raw))
	for scanner.Scan() {
		if value, ok := strings.CutPrefix(scanner.Text(), "Model:"); ok {
			return strings.TrimSpace(value)
		}
	}

	return ""
}

func driverOf(dir string) string {
	target, err := os.Readlink(filepath.Join(dir, "driver"))
	if err != nil {
		return ""
	}

	return filepath.Base(target)
}

func read(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}

	return strings.TrimSpace(string(raw))
}

type smiRow struct {
	bus    string
	model  string
	memory uint64
}

func nvidiaSMI() []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "nvidia-smi", "--query-gpu=pci.bus_id,name,memory.total", "--format=csv,noheader,nounits").Output()
	if err != nil {
		return nil
	}

	return out
}

func smiRows(raw []byte) []smiRow {
	rows := []smiRow{}
	scanner := bufio.NewScanner(bytes.NewReader(raw))

	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), ",")
		if len(fields) != 3 {
			continue
		}

		mebibytes, err := strconv.ParseUint(strings.TrimSpace(fields[2]), 10, 64)
		if err != nil {
			continue
		}

		rows = append(rows, smiRow{bus: strings.TrimSpace(fields[0]), model: strings.TrimSpace(fields[1]), memory: mebibytes << 20})
	}

	return rows
}
