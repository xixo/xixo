//go:build !darwin

package machine

const procRoot = "/proc"

var tailscaleApps []string

func native(*Health) {}
