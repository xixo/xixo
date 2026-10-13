package link

import (
	"errors"
	"slices"
	"sync"
)

var (
	ErrNotLentByXixo = errors.New("this machine does not lend its files' bytes: xixo has not turned on whole files for it")
	ErrOthersByXixo  = errors.New("this machine extracts only its own files: xixo has not asked it to read files for other machines")
)

type Settings struct {
	Tools             []string `json:"tools"`
	Lend              bool     `json:"lend"`
	ExtractsForOthers bool     `json:"extracts_for_others"`
}

type policy struct {
	lock sync.RWMutex
	held Settings
}

func (a *Link) Apply(settings Settings) {
	a.policy.lock.Lock()
	defer a.policy.lock.Unlock()

	a.policy.held = Settings{Tools: slices.Clone(settings.Tools), Lend: settings.Lend, ExtractsForOthers: settings.ExtractsForOthers}
}

func (a *Link) asked() Settings {
	a.policy.lock.RLock()
	defer a.policy.lock.RUnlock()

	return a.policy.held
}

func (a *Link) lent() error {
	switch {
	case !a.Lend:
		return ErrNotLent
	case !a.asked().Lend:
		return ErrNotLentByXixo
	}

	return nil
}

func (a *Link) helps() error {
	switch {
	case !a.ExtractsForOthers:
		return ErrOthers
	case !a.asked().ExtractsForOthers:
		return ErrOthersByXixo
	}

	return nil
}

func (a *Link) offers(tool string) bool {
	return a.unoffered(tool) == nil
}

func (a *Link) unoffered(tool string) error {
	switch {
	case !slices.Contains(a.Tools, tool):
		return &NotOffered{Tool: tool}
	case !slices.Contains(a.asked().Tools, tool):
		return &NotOffered{Tool: tool, ByXixo: true}
	}

	return nil
}
