package agent

import (
	"errors"
	"fmt"
	"io/fs"
	"runtime"
	"slices"

	"github.com/xixo/xixo/agent/internal/machine"
)

func (a *Agent) health() machine.Health {
	held := a.Machine.Health(a.Folders.Names())
	held.Warnings = a.warnings()

	return held
}

func (a *Agent) warnings() []string {
	held := slices.Clone(a.Notices)
	if held == nil {
		held = []string{}
	}

	unreadable := a.Folders.Unreadable()

	for _, folder := range a.Folders.Names() {
		if err, ok := unreadable[folder]; ok {
			held = append(held, Unreadable(folder, err))
		}
	}

	return held
}

func Unreadable(folder string, err error) string {
	switch {
	case errors.Is(err, fs.ErrPermission) && runtime.GOOS == "darwin":
		return fmt.Sprintf("macOS has not let xixo-agent read %s; allow it in System Settings → Privacy & Security → Full Disk Access, then restart the agent", folder)
	case errors.Is(err, fs.ErrPermission):
		return fmt.Sprintf("xixo-agent may not read %s", folder)
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Sprintf("the shared folder %s does not exist", folder)
	default:
		return fmt.Sprintf("xixo-agent cannot read %s: %v", folder, err)
	}
}
