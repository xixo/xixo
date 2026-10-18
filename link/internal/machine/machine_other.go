//go:build !darwin

package machine

import (
	"os"
	"strings"
)

const procRoot = "/proc"

var (
	osReleases  = []string{"/etc/os-release", "/usr/lib/os-release"}
	productName = "/sys/devices/virtual/dmi/id/product_name"
	chassisType = "/sys/devices/virtual/dmi/id/chassis_type"
	powerSupply = "/sys/class/power_supply"
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

func kind(_ string, battery bool) string {
	raw, _ := os.ReadFile(chassisType)

	return chassisKind(strings.TrimSpace(string(raw)), battery)
}

func chassisKind(chassis string, battery bool) string {
	switch chassis {
	case "8", "9", "10", "14", "30", "31", "32":
		return "laptop"
	case "13":
		return "all-in-one"
	case "3", "4", "5", "6", "7", "15", "16", "35", "36":
		return "desktop"
	case "17", "23", "28", "29":
		return "server"
	}

	if battery {
		return "laptop"
	}

	return "server"
}

func hasBattery() bool {
	held, err := os.ReadDir(powerSupply)
	if err != nil {
		return false
	}

	for _, entry := range held {
		if strings.HasPrefix(entry.Name(), "BAT") {
			return true
		}
	}

	return false
}
