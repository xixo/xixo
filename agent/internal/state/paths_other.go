//go:build !darwin

package state

var (
	DefaultConfig = "/etc/xixo-agent/config.json"
	DefaultState  = "/var/lib/xixo-agent"
	DefaultCache  = ""
	SearchPath    []string
)
