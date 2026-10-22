package updates

import (
	"fmt"
	"slices"

	"github.com/xixo/xixo/link/internal/verify"
)

const (
	Label      = "network.xixo.updates"
	OrderLabel = "network.xixo.updates.order"
	Created    = "org.opencontainers.image.created"
	Revision   = "org.opencontainers.image.revision"
	Version    = "org.opencontainers.image.version"
	LocalRepo  = "xixo-updates/"
	Current    = "current"
	Previous   = "previous"
	Main       = "main"
	Releases   = "releases"
)

type Kind struct {
	Name     string
	Image    string
	Signer   verify.Signer
	Channels map[string][]string
}

var Kinds = []Kind{
	{
		Name:     "masks",
		Image:    "ghcr.io/masksrb/masks",
		Signer:   verify.Signer{Repository: "masksrb/masks", Workflows: []string{"release.yml"}},
		Channels: map[string][]string{Main: {"release.yml"}, Releases: {"release.yml"}},
	},
	{
		Name:     "xixo",
		Image:    "ghcr.io/xixo/xixo",
		Signer:   verify.Signer{Repository: "xixo/xixo", Workflows: []string{"ci.yml", "release.yml"}},
		Channels: map[string][]string{Main: {"ci.yml"}, Releases: {"release.yml"}},
	},
	{
		Name:     "xixo-link",
		Image:    "ghcr.io/xixo/xixo-link",
		Signer:   verify.Signer{Repository: "xixo/xixo", Workflows: []string{"ci.yml", "release.yml"}},
		Channels: map[string][]string{Main: {"ci.yml"}, Releases: {"release.yml"}},
	},
}

func Named(name string) (Kind, error) {
	for _, kind := range Kinds {
		if kind.Name == name {
			return kind, nil
		}
	}

	return Kind{}, fmt.Errorf("%q is not something the updater keeps up to date", name)
}

func (k Kind) Local(tag string) string {
	return LocalRepo + k.Name + ":" + tag
}

func (k Kind) On(channel string) (verify.Signer, error) {
	workflows, known := k.Channels[channel]
	if !known {
		return verify.Signer{}, fmt.Errorf("%q is not a channel: name main or releases", channel)
	}

	return verify.Signer{Repository: k.Signer.Repository, Workflows: slices.Clone(workflows)}, nil
}
