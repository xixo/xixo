package link

import (
	"errors"
	"fmt"
	"io/fs"
	"runtime"
	"slices"

	"github.com/xixo/xixo/link/internal/machine"
)

func (a *Link) health() machine.Health {
	held := a.Machine.Health(a.Folders.Names())
	held.Warnings = a.warnings()

	return held
}

func (a *Link) warnings() []string {
	held := slices.Clone(a.Notices)
	if held == nil {
		held = []string{}
	}

	if a.watching != nil {
		held = append(held, a.watching.Warnings()...)
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
		return fmt.Sprintf("macOS has not let xixo-link read %s; allow it in System Settings → Privacy & Security → Full Disk Access, then restart xixo link", folder)
	case errors.Is(err, fs.ErrPermission):
		return fmt.Sprintf("xixo-link may not read %s", folder)
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Sprintf("the shared folder %s does not exist", folder)
	default:
		return fmt.Sprintf("xixo-link cannot read %s: %v", folder, err)
	}
}
