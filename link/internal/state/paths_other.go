//go:build !darwin

package state

var (
	DefaultConfig = "/etc/xixo-link/config.json"
	DefaultState  = "/var/lib/xixo-link"
	DefaultCache  = ""
	SearchPath    []string
)
