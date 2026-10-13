package link

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/folders"
	"github.com/xixo/xixo/link/internal/machine"
	"github.com/xixo/xixo/link/internal/state"
)

const (
	verbBrowse  = "browse"
	verbFind    = "find"
	verbPeek    = "peek"
	verbPlace   = "place"
	verbExamine = "examine"
	verbModel   = "model"
	verbRelay   = "relay"

	MostBrowsed  = 200
	MostFound    = 100
	MostVisited  = 20000
	MostQuery    = 200
	MostPeeked   = 256 << 10
	MostPlaced   = 1 << 20
	MostStep     = 256 << 10
	FoundWithin  = 10 * time.Second
	ExamineUntil = 2 * time.Minute
)

var toolFor = map[string]string{
	verbBrowse:  state.ToolBrowse,
	verbFind:    state.ToolSearch,
	verbPeek:    state.ToolRead,
	verbPlace:   state.ToolWrite,
	verbExamine: state.ToolExtract,
	verbModel:   state.ToolModels,
	verbRelay:   state.ToolModels,
}

var (
	ErrNoQuery    = fmt.Errorf("a search names between 1 and %d characters to look for", MostQuery)
	ErrPlacedSize = fmt.Errorf("a file written through a tool holds at most %d bytes", MostPlaced)
	ErrNoFolder   = errors.New("this tool reads a shared file, named by folder and path")
)

type NotOffered struct {
	Tool   string
	ByXixo bool
}

func (e *NotOffered) Error() string {
	if e.ByXixo {
		return fmt.Sprintf("this machine does not offer the %s tool: xixo has not turned on %s for it", e.Tool, e.Tool)
	}

	return fmt.Sprintf("this machine does not offer the %s tool: its config leaves %s out of tools", e.Tool, e.Tool)
}

type greeting struct {
	machine.Hello
	Tools     []string `json:"tools"`
	Updates   string   `json:"updates,omitempty"`
	SHA256    string   `json:"sha256,omitempty"`
	MacReader string   `json:"mac_reader,omitempty"`
}

func (a *Link) offered() []string {
	held := []string{}

	for _, tool := range state.Tools {
		if slices.Contains(a.Tools, tool) {
			held = append(held, tool)
		}
	}

	return held
}

func (a *Link) tool(ctx context.Context, asked *Request) {
	named := toolFor[asked.Verb]
	if err := a.unoffered(named); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	var answered any
	var err error

	switch asked.Verb {
	case verbBrowse:
		answered, err = a.browse(ctx, asked.Args)
	case verbFind:
		answered, err = a.find(ctx, asked.Args)
	case verbPeek:
		answered, err = a.peek(asked.Args)
	case verbPlace:
		answered, err = a.place(ctx, asked.Args)
	case verbExamine:
		answered, err = a.examine(ctx, asked.Args)
	case verbModel:
		answered, err = a.model(ctx, asked.Args)
	case verbRelay:
		answered, err = a.relay(ctx, asked.Args)
	}

	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	a.reply(ctx, asked.Request, answered)
}

type Browsing struct {
	Folder string `json:"folder"`
	Prefix string `json:"prefix,omitempty"`
	Cursor string `json:"cursor,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}

func (a *Link) browse(ctx context.Context, raw json.RawMessage) (any, error) {
	wanted := Browsing{}
	if err := strictly(raw, &wanted); err != nil {
		return nil, err
	}

	limit := wanted.Limit
	if limit <= 0 || limit > MostBrowsed {
		limit = MostBrowsed
	}

	return a.Folders.List(ctx, folders.Query{Folder: wanted.Folder, Prefix: wanted.Prefix, Cursor: wanted.Cursor, Limit: limit})
}

type Finding struct {
	Query  string `json:"query"`
	Folder string `json:"folder,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}

type Found struct {
	Folder     string    `json:"folder"`
	Path       string    `json:"path"`
	Size       int64     `json:"size"`
	ModifiedAt time.Time `json:"modified_at"`
}

type Finds struct {
	Matches  []Found `json:"matches"`
	Visited  int     `json:"visited"`
	Complete bool    `json:"complete"`
}

func (a *Link) find(ctx context.Context, raw json.RawMessage) (any, error) {
	wanted := Finding{}
	if err := strictly(raw, &wanted); err != nil {
		return nil, err
	}

	query := strings.ToLower(strings.TrimSpace(wanted.Query))
	if query == "" || utf8.RuneCountInString(query) > MostQuery {
		return nil, ErrNoQuery
	}

	limit := wanted.Limit
	if limit <= 0 || limit > MostFound {
		limit = MostFound
	}

	walked := a.Folders.Names()
	if wanted.Folder != "" {
		if !a.Folders.Shares(wanted.Folder) {
			return nil, folders.ErrUnshared
		}

		walked = []string{wanted.Folder}
	}

	held := &Finds{Matches: []Found{}, Complete: true}
	deadline := time.Now().Add(FoundWithin)

	for _, folder := range walked {
		cursor := ""

		for {
			if held.Visited >= MostVisited || time.Now().After(deadline) {
				held.Complete = false

				return held, nil
			}

			listed, err := a.Folders.List(ctx, folders.Query{Folder: folder, Cursor: cursor, Limit: folders.MostListed})
			if err != nil {
				return nil, err
			}

			for _, entry := range listed.Entries {
				held.Visited++

				if !strings.Contains(strings.ToLower(entry.Path), query) {
					continue
				}

				if len(held.Matches) == limit {
					held.Complete = false

					return held, nil
				}

				held.Matches = append(held.Matches, Found{Folder: folder, Path: entry.Path, Size: entry.Size, ModifiedAt: entry.ModifiedAt})
			}

			if listed.Cursor == "" {
				break
			}

			cursor = listed.Cursor
		}
	}

	return held, nil
}

type Peeked struct {
	Data  string `json:"data"`
	Size  int64  `json:"size"`
	Total int64  `json:"total"`
}

type Peeking struct {
	Folder string `json:"folder"`
	Path   string `json:"path"`
	Limit  int64  `json:"limit,omitempty"`
}

func (a *Link) peek(raw json.RawMessage) (any, error) {
	if err := a.lent(); err != nil {
		return nil, err
	}

	wanted := Peeking{}
	if err := strictly(raw, &wanted); err != nil {
		return nil, err
	}

	limit := wanted.Limit
	if limit <= 0 || limit > MostPeeked {
		limit = MostPeeked
	}

	opened, err := a.Folders.Open(wanted.Folder, wanted.Path)
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	head, err := io.ReadAll(io.LimitReader(opened, limit))
	if err != nil {
		return nil, err
	}

	return Peeked{Data: base64.StdEncoding.EncodeToString(head), Size: int64(len(head)), Total: opened.Size}, nil
}

func (a *Link) place(ctx context.Context, raw json.RawMessage) (any, error) {
	wanted := Writing{}
	if err := strictly(raw, &wanted); err != nil {
		return nil, err
	}

	if wanted.Size < 0 || wanted.Size > MostPlaced {
		return nil, ErrPlacedSize
	}

	return a.written(ctx, wanted)
}

type Examined struct {
	Digest
	Extractor string                  `json:"extractor"`
	Steps     map[string]extract.Step `json:"steps"`
	Dropped   map[string]string       `json:"dropped,omitempty"`
}

func (a *Link) examine(ctx context.Context, raw json.RawMessage) (any, error) {
	wanted := Extraction{}
	if err := decode(raw, &wanted); err != nil {
		return nil, err
	}

	if wanted.Source.Upload != "" || wanted.Source.Folder == "" || wanted.Source.Path == "" {
		return nil, ErrNoFolder
	}

	ctx, cancel := context.WithTimeout(ctx, ExamineUntil)
	defer cancel()

	work, err := os.MkdirTemp(a.Work, "examine-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)

	path, digest, err := a.source(ctx, wanted, work)
	if err != nil {
		return nil, err
	}

	in := extract.Input{
		Path: path,
		Name: filepath.Base(wanted.Source.Path),
		MIME: wanted.MIME,
		Size: digest.Size,
		Skip: map[string]bool{},
		Work: work,
		Run:  extract.Within(a.Runner, work, MostWork),
		Set:  wanted.Settings,
	}

	out, err := a.Extract(ctx, in)
	if err != nil {
		return nil, err
	}

	held := Examined{Digest: digest, Extractor: out.Extractor, Steps: map[string]extract.Step{}, Dropped: out.Dropped}

	for name, step := range out.Steps {
		encoded, err := json.Marshal(step)
		if err != nil || len(encoded) > MostStep {
			if held.Dropped == nil {
				held.Dropped = map[string]string{}
			}

			held.Dropped[name] = fmt.Sprintf("the %s step made more than %d bytes, so a tool call does not carry it", name, MostStep)

			continue
		}

		held.Steps[name] = step
	}

	return held, nil
}

func strictly(raw json.RawMessage, into any) error {
	if len(raw) == 0 {
		return errors.New("the request holds no args")
	}

	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(into); err != nil {
		return fmt.Errorf("the request's args do not fit: %w", err)
	}

	return nil
}
