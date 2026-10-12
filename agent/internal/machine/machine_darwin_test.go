package machine

import (
	"encoding/binary"
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
