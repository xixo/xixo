//go:build !darwin

package machine

import (
	"os"
	"strings"
)

const procRoot = "/proc"

var tailscaleApps []string

var (
	osReleases  = []string{"/etc/os-release", "/usr/lib/os-release"}
	productName = "/sys/devices/virtual/dmi/id/product_name"
)

func native(*Health) {}

func system() string {
	for _, path := range osReleases {
		if raw, err := os.ReadFile(path); err == nil {
			if held := osRelease(raw); held != "" {
				return held
			}
		}
	}

	return "Linux"
}

func model() string {
	raw, err := os.ReadFile(productName)
	if err != nil {
		return ""
	}

	held := strings.TrimSpace(string(raw))
	switch strings.ToLower(held) {
	case "", "to be filled by o.e.m.", "system product name", "default string", "none":
		return ""
	}

	return held
}
