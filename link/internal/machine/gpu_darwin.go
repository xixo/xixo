package machine

import (
	"runtime"
	"strings"

	"golang.org/x/sys/unix"
)

const MakerApple = "Apple"

func (m *Machine) GPUs() []GPU {
	if runtime.GOARCH != "arm64" {
		return []GPU{}
	}

	chip, _ := unix.Sysctl("machdep.cpu.brand_string")
	memory, _ := unix.SysctlUint64("hw.memsize")

	return []GPU{{Maker: MakerApple, Model: strings.TrimSpace(chip), Memory: memory, Driver: "built in"}}
}
