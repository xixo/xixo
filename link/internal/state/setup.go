package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"unicode"

	"github.com/xixo/xixo/link/internal/folders"
)

const writableSuffix = ":rw"

var account = regexp.MustCompile(`(?i)\A[a-z_][a-z0-9_.-]{0,31}\z`)

func unshareable(path string) error {
	if strings.IndexFunc(path, func(r rune) bool { return unicode.IsControl(r) || strings.ContainsRune(`"'\:`, r) }) >= 0 {
		return fmt.Errorf("the folder %q holds a quote, a backslash, a colon, or a control character, which xixo link cannot share", path)
	}

	if !filepath.IsAbs(path) {
		return fmt.Errorf("the folder %q is not a full path. Name it from /, or with ~/ for a folder in your home folder", path)
	}

	return nil
}

func Folder(arg string) (folders.Shared, error) {
	path, writable := strings.CutSuffix(arg, writableSuffix)

	if err := unshareable(path); err != nil {
		return folders.Shared{}, err
	}

	path = filepath.Clean(path)

	info, err := os.Stat(path)

	switch {
	case errors.Is(err, fs.ErrNotExist):
		return folders.Shared{}, fmt.Errorf("the folder %s does not exist. Check its path, then run the command again", path)
	case errors.Is(err, fs.ErrPermission):
		return folders.Shared{}, fmt.Errorf("this account cannot open the folder %s. Run the command as the account that owns it", path)
	case err != nil:
		return folders.Shared{}, fmt.Errorf("xixo link cannot share the folder %s: %w", path, err)
	case !info.IsDir():
		return folders.Shared{}, fmt.Errorf("%s is a file. Name the folder that holds it instead", path)
	}

	return folders.Shared{Path: path, Writable: writable}, nil
}

func Setup(path, xixo, issuer string, args []string) (*Config, error) {
	raw := map[string]json.RawMessage{}

	held, err := os.ReadFile(path)

	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(held, &raw); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
	}

	raw["xixo"], _ = json.Marshal(xixo)
	raw["issuer"], _ = json.Marshal(issuer)

	if len(args) > 0 {
		listed := []any{}

		for _, arg := range args {
			shared, err := Folder(arg)
			if err != nil {
				return nil, err
			}

			if shared.Writable {
				listed = append(listed, shared)
			} else {
				listed = append(listed, shared.Path)
			}
		}

		raw["folders"], _ = json.Marshal(listed)
	}

	if _, ok := raw["folders"]; !ok {
		raw["folders"] = json.RawMessage("[]")
	}

	encoded, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		return nil, err
	}

	config := &Config{}
	if err := json.Unmarshal(encoded, config); err != nil {
		return nil, err
	}

	if err := config.check(); err != nil {
		return nil, err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}

	return config, written(path, append(encoded, '\n'), configMode())
}

func configMode() os.FileMode {
	if runtime.GOOS == "darwin" {
		return 0o600
	}

	return 0o644
}

func Unit(template, user string, shared []folders.Shared) (string, error) {
	if !account.MatchString(user) {
		return "", fmt.Errorf("%q is not an account name xixo link runs as", user)
	}

	if !strings.Contains(template, "User=@USER@") {
		return "", errors.New("the service template names no User=@USER@ to run xixo link as")
	}

	if !strings.Contains(template, "\n@FOLDERS@\n") {
		return "", errors.New("the service template names no @FOLDERS@ line to share folders through")
	}

	read, writes := []string{}, []string{}

	for _, folder := range shared {
		if err := unshareable(folder.Path); err != nil {
			return "", err
		}

		quoted := `"-` + strings.ReplaceAll(folder.Path, "%", "%%") + `"`

		if folder.Writable {
			writes = append(writes, quoted)
		} else {
			read = append(read, quoted)
		}
	}

	bound := ""

	if len(read) > 0 {
		bound += "BindReadOnlyPaths=" + strings.Join(read, " ") + "\n"
	}

	if len(writes) > 0 {
		bound += "BindPaths=" + strings.Join(writes, " ") + "\n"
	}

	return strings.Replace(strings.ReplaceAll(template, "@USER@", user), "@FOLDERS@\n", bound, 1), nil
}
