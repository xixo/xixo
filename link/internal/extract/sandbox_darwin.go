package extract

import (
	"fmt"
	"os"
	"path/filepath"
)

var sandboxExec = "/usr/bin/sandbox-exec"

func Sandbox() (Confiner, error) {
	info, err := os.Stat(sandboxExec)
	if err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: %s is missing", ErrNoSandbox, sandboxExec)
	}

	return confine, nil
}

func confine(work, program string) ([]string, error) {
	if work == "" {
		return nil, ErrNoWork
	}

	real, err := filepath.EvalSymlinks(work)
	if err != nil {
		return nil, err
	}

	profile, err := Profile(real, program)
	if err != nil {
		return nil, err
	}

	return []string{sandboxExec, "-p", profile}, nil
}
