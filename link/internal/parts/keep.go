package parts

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"sync"
	"time"
)

const Pause = 10 * time.Second

type Keeper struct {
	Dir     string
	Allowed []string
	Status  func(name string) string
	Command func(ctx context.Context, name string) *exec.Cmd

	lock     sync.Mutex
	children map[string]context.CancelFunc
	work     sync.WaitGroup
}

func (k *Keeper) Apply(ctx context.Context, wanted map[string]Settings) {
	k.lock.Lock()
	defer k.lock.Unlock()

	for _, name := range Known() {
		settings, asked := wanted[name]
		if asked && slices.Contains(k.Allowed, name) {
			k.want(ctx, name, settings)
		} else {
			k.unwant(name)
		}
	}
}

func (k *Keeper) want(ctx context.Context, name string, settings Settings) {
	if err := WriteWanted(k.path(name), Wanted{Version: Recipes[name].Version, Settings: settings}); err != nil {
		return
	}

	if k.Command == nil || k.children[name] != nil {
		return
	}

	if k.children == nil {
		k.children = map[string]context.CancelFunc{}
	}

	ctx, cancel := context.WithCancel(ctx)
	k.children[name] = cancel
	k.work.Add(1)

	go k.keep(ctx, name)
}

func (k *Keeper) unwant(name string) {
	Unwant(k.path(name))

	if cancel := k.children[name]; cancel != nil {
		cancel()
		delete(k.children, name)
	}
}

func (k *Keeper) keep(ctx context.Context, name string) {
	defer k.work.Done()

	for {
		if _, err := os.Stat(k.path(name)); errors.Is(err, fs.ErrNotExist) {
			return
		}

		command := k.Command(ctx, name)
		if command.Start() == nil {
			command.Wait()
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(Pause):
		}
	}
}

func (k *Keeper) Statuses() []Status {
	held := []Status{}

	for _, name := range Known() {
		if _, err := os.Stat(k.path(name)); errors.Is(err, fs.ErrNotExist) {
			continue
		}

		status, err := ReadStatus(k.Status(name))
		if err != nil {
			status = Status{Name: name, Version: Recipes[name].Version, State: StateMissing, Pulls: []Pull{}}
		}

		status.Name = name
		held = append(held, status)
	}

	sort.Slice(held, func(a, b int) bool { return held[a].Name < held[b].Name })

	return held
}

type Served struct {
	Kind string
	Port int
}

func (k *Keeper) Serving() []Served {
	held := []Served{}

	for _, status := range k.Statuses() {
		if status.State != StateRunning || status.Port <= 0 {
			continue
		}

		if kind := Recipes[status.Name].Kind; kind != "" {
			held = append(held, Served{Kind: kind, Port: status.Port})
		}
	}

	return held
}

func (k *Keeper) Wait() {
	k.work.Wait()
}

func (k *Keeper) path(name string) string {
	return filepath.Join(k.Dir, name)
}
