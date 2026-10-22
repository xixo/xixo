package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/xixo/xixo/link/internal/release"
)

func main() {
	dir := flag.String("dir", "", "the folder that holds the builds, units, launch agent, and mac/xixo-mac-reader")
	version := flag.String("version", "", "the version every build reports, such as 0.2.0+1a2b3c4")
	revision := flag.String("revision", "", "the full commit the builds came from")
	serial := flag.Int64("serial", 0, "the number of commits on main up to that commit")
	flag.Parse()

	held, err := release.Describe(*dir, *version, *revision, release.Channel(*version), *serial)
	if err != nil {
		fmt.Fprintln(os.Stderr, "link-release:", err)
		os.Exit(1)
	}

	raw, err := json.MarshalIndent(held, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "link-release:", err)
		os.Exit(1)
	}

	if err := os.WriteFile(filepath.Join(*dir, release.File), append(raw, '\n'), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "link-release:", err)
		os.Exit(1)
	}

	fmt.Printf("wrote %s: %s, serial %d, %d files\n", filepath.Join(*dir, release.File), held.Version, held.Serial, len(held.Files))
}
