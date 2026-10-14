package extract

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Confiner func(work, program string, reads []string) ([]string, error)

var (
	ErrNoSandbox  = errors.New("this machine has no sandbox-exec")
	ErrUnconfined = errors.New("xixo link runs no extraction program outside a sandbox, and this machine has none; set extract_unsandboxed in the config to run them anyway")
	ErrNoWork     = errors.New("a sandboxed program needs a work folder")
	ErrNoRead     = errors.New("a sandboxed program reads a shared file only by its absolute path")
)

var sandboxReads = []string{
	"/bin", "/sbin", "/usr", "/opt/homebrew", "/usr/local",
	"/private/etc", "/private/var/select", "/Library/Fonts", "/Library/Perl", "/System/Library/Fonts",
}

var (
	sandboxHidden  = []string{"/opt/homebrew/var", "/opt/homebrew/etc", "/usr/local/var", "/usr/local/etc"}
	sandboxReshown = []string{"/opt/homebrew/etc/fonts", "/usr/local/etc/fonts"}
)

var (
	readerClients  = []string{"IOSurfaceRootUserClient", "AGXDeviceUserClient", "H11ANEInDirectPathClient"}
	readerServices = []string{"com.apple.appleneuralengine", "com.apple.audio.AudioComponentRegistrar"}
)

var officeServices = []string{
	"com.apple.coreservices.launchservicesd", "com.apple.CoreServices.coreservicesd", "com.apple.SystemConfiguration.configd",
	"com.apple.windowserver.active", "com.apple.DiskArbitration.diskarbitrationd", "com.apple.tccd.system",
	"com.apple.pasteboard.1", "com.apple.PowerManagement.control",
}

func Profile(work, program string, reads ...string) (string, error) {
	if work == "" || !filepath.IsAbs(work) {
		return "", ErrNoWork
	}

	work = filepath.Clean(work)

	var held strings.Builder

	held.WriteString("(version 1)\n(deny default)\n(import \"system.sb\")\n")
	held.WriteString("(allow process-fork)\n(allow process-exec)\n(allow signal (target same-sandbox))\n(allow sysctl-read)\n")
	held.WriteString("(allow file-read-metadata (literal \"/\")" + literals(ancestors(work)) + ")\n")
	held.WriteString("(allow file-read*" + subpaths(sandboxReads) + subpaths([]string{work}) + ")\n")
	held.WriteString("(deny file-read*" + subpaths(sandboxHidden) + ")\n")
	held.WriteString("(allow file-read*" + subpaths(sandboxReshown) + ")\n")
	held.WriteString("(allow file-write*" + subpaths([]string{work}) + ")\n")

	if IsMacReader(program) && filepath.IsAbs(program) {
		held.WriteString("(allow file-read* (literal " + quoted(filepath.Clean(program)) + "))\n")
		held.WriteString("(allow file-read* (literal " + quoted(filepath.Dir(filepath.Clean(program))) + "))\n")
		held.WriteString("(allow file-read-metadata" + literals(ancestors(filepath.Clean(program))) + ")\n")
		held.WriteString("(allow iokit-open (iokit-user-client-class" + quotedAll(readerClients) + "))\n")
		held.WriteString("(allow mach-lookup (global-name" + quotedAll(readerServices) + "))\n")
	}

	for _, read := range reads {
		if !filepath.IsAbs(read) {
			return "", ErrNoRead
		}

		read = filepath.Clean(read)
		held.WriteString("(allow file-read-metadata" + literals(ancestors(read)) + ")\n")
		held.WriteString("(allow file-read* (literal " + quoted(read) + "))\n")
	}

	if filepath.Base(program) == "soffice" {
		held.WriteString("(allow file-read*" + subpaths([]string{"/Applications/LibreOffice.app"}) + ")\n")
		held.WriteString("(allow file-read-metadata (literal \"/Applications\") (literal \"/Users\")" + home() + ")\n")
		held.WriteString("(allow mach-lookup (global-name" + quotedAll(officeServices) + "))\n")
		held.WriteString("(allow file-read* file-write* (regex #\"^/private/tmp/OSL_PIPE_\"))\n")
		held.WriteString("(allow network-bind network-outbound network-inbound (regex #\"^/private/tmp/OSL_PIPE_\"))\n")
		held.WriteString("(allow file-read-metadata file-write-data (literal \"/private/tmp\") (literal \"/tmp\"))\n")
	}

	return held.String(), nil
}

func home() string {
	dir, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(dir) {
		return ""
	}

	return literals([]string{filepath.Clean(dir)})
}

func ancestors(path string) []string {
	held := []string{}

	for dir := filepath.Dir(path); dir != "/" && dir != "."; dir = filepath.Dir(dir) {
		held = append(held, dir)
	}

	return held
}

func literals(paths []string) string {
	var held strings.Builder
	for _, path := range paths {
		fmt.Fprintf(&held, " (literal %s)", quoted(path))
	}

	return held.String()
}

func subpaths(paths []string) string {
	var held strings.Builder
	for _, path := range paths {
		fmt.Fprintf(&held, " (subpath %s)", quoted(path))
	}

	return held.String()
}

func quotedAll(names []string) string {
	var held strings.Builder
	for _, name := range names {
		held.WriteString(" " + quoted(name))
	}

	return held.String()
}

func quoted(raw string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(raw) + `"`
}
