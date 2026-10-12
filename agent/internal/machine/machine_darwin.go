package machine

import (
	"encoding/binary"
	"time"

	"golang.org/x/sys/unix"
)

const procRoot = ""

var tailscaleApps = []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale"}

func native(held *Health) {
	if booted, err := unix.SysctlTimeval("kern.boottime"); err == nil {
		seconds, nanoseconds := booted.Unix()
		held.Uptime = time.Since(time.Unix(seconds, nanoseconds)).Seconds()
	}

	if raw, err := unix.SysctlRaw("vm.loadavg"); err == nil {
		held.Load = loads(raw)
	}

	total, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return
	}

	held.Memory.Total = total
	held.Memory.Available = available(total)
}

func loads(raw []byte) []float64 {
	held := []float64{0, 0, 0}
	if len(raw) < 24 {
		return held
	}

	scale := float64(binary.LittleEndian.Uint64(raw[16:24]))
	if scale <= 0 {
		return held
	}

	for index := range held {
		held[index] = float64(binary.LittleEndian.Uint32(raw[index*4:])) / scale
	}

	return held
}

func available(total uint64) uint64 {
	if level, err := unix.SysctlUint32("kern.memorystatus_level"); err == nil && level > 0 && level <= 100 {
		return total / 100 * uint64(level)
	}

	page, err := unix.SysctlUint32("hw.pagesize")
	if err != nil {
		return 0
	}

	pages := uint64(0)

	for _, name := range []string{"vm.page_free_count", "vm.page_speculative_count", "vm.page_purgeable_count", "vm.page_pageable_external_count"} {
		if count, err := unix.SysctlUint32(name); err == nil {
			pages += uint64(count)
		}
	}

	return min(pages*uint64(page), total)
}
