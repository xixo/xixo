package release

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const (
	File         = "release.json"
	Bundle       = "release.sigstore.json"
	MostFile     = 1 << 20
	MostFiles    = 64
	MostPackages = 64
	RoleBinary   = "binary"
	RoleReader   = "mac_reader"
	RoleUnit     = "unit"
	RolePlist    = "plist"
	Service      = "xixo-link.service"
	Plist        = "xixo-link.plist"
	MacReader    = "xixo-mac-reader"
	MacDir       = "mac"
)

var (
	Versioned = regexp.MustCompile(`^\d{1,6}\.\d{1,6}\.\d{1,6}(\+[0-9a-f]{7,40})?$`)
	Hexed     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	UnitName  = regexp.MustCompile(`^xixo-link[a-z@-]*\.(service|path|timer)$`)

	Packages = []string{
		"ca-certificates", "libvips-tools", "libraw-bin", "libimage-exiftool-perl", "libarchive-zip-perl", "poppler-utils",
		"tesseract-ocr", "ffmpeg", "libreoffice-writer", "libreoffice-calc", "fonts-liberation",
	}

	binaryName  = regexp.MustCompile(`^xixo-link-(linux|darwin)-(amd64|arm64)$`)
	packageName = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]{1,62}$`)
	revised     = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

type Entry struct {
	Name   string `json:"name"`
	OS     string `json:"os,omitempty"`
	Arch   string `json:"arch,omitempty"`
	Role   string `json:"role"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Release struct {
	Version     string   `json:"version"`
	Serial      int64    `json:"serial"`
	Revision    string   `json:"revision"`
	Channel     string   `json:"channel"`
	PackagesApt []string `json:"packages_apt"`
	Files       []Entry  `json:"files"`
}

func (r Release) Check() error {
	switch {
	case !Versioned.MatchString(r.Version):
		return fmt.Errorf("the release names the version %q", r.Version)
	case r.Serial <= 0:
		return errors.New("the release has no serial")
	case !revised.MatchString(r.Revision):
		return fmt.Errorf("the release names the commit %q", r.Revision)
	case r.Channel != "main" && r.Channel != "releases":
		return fmt.Errorf("the release names the channel %q", r.Channel)
	case len(r.Files) == 0 || len(r.Files) > MostFiles:
		return fmt.Errorf("the release lists %d files", len(r.Files))
	case len(r.PackagesApt) > MostPackages:
		return fmt.Errorf("the release lists %d apt packages", len(r.PackagesApt))
	}

	for _, name := range r.PackagesApt {
		if !packageName.MatchString(name) {
			return fmt.Errorf("the release lists the apt package %q", name)
		}
	}

	seen := map[string]bool{}

	for _, entry := range r.Files {
		if err := entry.check(); err != nil {
			return err
		}

		if seen[entry.Name] {
			return fmt.Errorf("the release lists %q twice", entry.Name)
		}

		seen[entry.Name] = true
	}

	return nil
}

func (e Entry) check() error {
	if !Hexed.MatchString(e.SHA256) || e.Size <= 0 {
		return fmt.Errorf("the release lists %q with no SHA-256 or size", e.Name)
	}

	switch e.Role {
	case RoleBinary:
		found := binaryName.FindStringSubmatch(e.Name)
		if found == nil || found[1] != e.OS || found[2] != e.Arch {
			return fmt.Errorf("the release lists the build %q for %s/%s", e.Name, e.OS, e.Arch)
		}
	case RoleReader:
		if e.Name != MacDir+"/"+MacReader {
			return fmt.Errorf("the release lists the mac reader as %q", e.Name)
		}
	case RoleUnit:
		if !UnitName.MatchString(e.Name) {
			return fmt.Errorf("the release lists the unit %q", e.Name)
		}
	case RolePlist:
		if e.Name != Plist {
			return fmt.Errorf("the release lists the launch agent as %q", e.Name)
		}
	default:
		return fmt.Errorf("the release lists %q in the role %q", e.Name, e.Role)
	}

	return nil
}

func (r Release) Build(goos, goarch string) (Entry, bool) {
	return r.find(func(entry Entry) bool { return entry.Role == RoleBinary && entry.OS == goos && entry.Arch == goarch })
}

func (r Release) Reader() (Entry, bool) {
	return r.find(func(entry Entry) bool { return entry.Role == RoleReader })
}

func (r Release) LaunchAgent() (Entry, bool) {
	return r.find(func(entry Entry) bool { return entry.Role == RolePlist })
}

func (r Release) Units() []Entry {
	held := []Entry{}

	for _, entry := range r.Files {
		if entry.Role == RoleUnit {
			held = append(held, entry)
		}
	}

	return held
}

func (r Release) Linux(goarch string) ([]Entry, error) {
	build, found := r.Build("linux", goarch)
	if !found {
		return nil, fmt.Errorf("the release has no build for linux/%s", goarch)
	}

	units := r.Units()
	if len(units) == 0 {
		return nil, errors.New("the release lists no systemd units")
	}

	return append([]Entry{build}, units...), nil
}

func (r Release) find(wanted func(Entry) bool) (Entry, bool) {
	for _, entry := range r.Files {
		if wanted(entry) {
			return entry, true
		}
	}

	return Entry{}, false
}

func Parse(raw []byte) (Release, error) {
	if len(raw) > MostFile {
		return Release{}, fmt.Errorf("the release is larger than %d bytes", MostFile)
	}

	held := Release{}
	if err := json.Unmarshal(raw, &held); err != nil {
		return Release{}, err
	}

	return held, held.Check()
}

func Sum(raw []byte) string {
	sum := sha256.Sum256(raw)

	return hex.EncodeToString(sum[:])
}

func ID(raw []byte) string {
	return Sum(raw)[:16]
}

func Describe(dir, version, revision string, serial int64) (Release, error) {
	held := Release{Version: version, Serial: serial, Revision: revision, Channel: Channel(version), PackagesApt: Packages, Files: []Entry{}}

	names, err := os.ReadDir(dir)
	if err != nil {
		return Release{}, err
	}

	paths := []string{}
	for _, name := range names {
		if name.Type().IsRegular() {
			paths = append(paths, name.Name())
		}
	}

	if info, err := os.Lstat(filepath.Join(dir, MacDir, MacReader)); err == nil && info.Mode().IsRegular() {
		paths = append(paths, MacDir+"/"+MacReader)
	}

	sort.Strings(paths)

	for _, name := range paths {
		entry := Entry{Name: name}

		switch found := binaryName.FindStringSubmatch(name); {
		case found != nil:
			entry.Role, entry.OS, entry.Arch = RoleBinary, found[1], found[2]
		case name == MacDir+"/"+MacReader:
			entry.Role, entry.OS, entry.Arch = RoleReader, "darwin", "universal"
		case UnitName.MatchString(name):
			entry.Role = RoleUnit
		case name == Plist:
			entry.Role = RolePlist
		default:
			continue
		}

		if entry.SHA256, entry.Size, err = Digest(filepath.Join(dir, filepath.FromSlash(name))); err != nil {
			return Release{}, err
		}

		held.Files = append(held.Files, entry)
	}

	return held, held.Check()
}

func Digest(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()

	sum := sha256.New()
	size, err := io.Copy(sum, file)
	if err != nil {
		return "", 0, err
	}

	return hex.EncodeToString(sum.Sum(nil)), size, nil
}

func Channel(version string) string {
	if strings.Contains(version, "+") {
		return "main"
	}

	return "releases"
}
