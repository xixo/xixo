package agent

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	MostUpload  = 4 << 30
	MostFiles   = 256
	UploadKept  = 15 * time.Minute
	MostUploads = 8
	verbPut     = "put"
	verbExtract = "extract"
	verbDerive  = "derive"
)

var (
	ErrNoUpload   = errors.New("no upload holds that id")
	ErrUploadSize = errors.New("the upload's size does not match what arrived")
	ErrTooLarge   = errors.New("the upload is larger than the agent keeps")
	ErrOutOfOrder = errors.New("an upload's pieces arrived out of order")
	ErrBusy       = errors.New("the agent is holding as many uploads as it keeps")
)

type Put struct {
	Seq  *int   `json:"seq,omitempty"`
	Data string `json:"data,omitempty"`
	Done bool   `json:"done,omitempty"`
	Size *int64 `json:"size,omitempty"`
}

type Source struct {
	Upload string `json:"upload,omitempty"`
	Folder string `json:"folder,omitempty"`
	Path   string `json:"path,omitempty"`
}

type Extraction struct {
	Source   Source           `json:"source"`
	MIME     string           `json:"mime"`
	Filename string           `json:"filename"`
	Size     int64            `json:"size"`
	Skip     []string         `json:"skip"`
	Settings extract.Settings `json:"settings"`
}

type Sent struct {
	Role        string   `json:"role"`
	Name        string   `json:"name"`
	MIME        string   `json:"mime"`
	Size        int64    `json:"size"`
	RequestFile string   `json:"request_file"`
	At          *float64 `json:"at,omitempty"`
}

type Extracted struct {
	Extractor string                  `json:"extractor"`
	Steps     map[string]extract.Step `json:"steps"`
	Dropped   map[string]string       `json:"dropped,omitempty"`
	Files     []Sent                  `json:"files"`
}

type upload struct {
	file     *os.File
	size     int64
	next     int
	done     bool
	taken    bool
	failed   error
	lastSeen time.Time
}

type uploads struct {
	mu   sync.Mutex
	dir  string
	held map[string]*upload
}

func newUploads(dir string) *uploads {
	return &uploads{dir: dir, held: map[string]*upload{}}
}

func (u *uploads) put(id string, piece Put) (int64, bool, error) {
	u.mu.Lock()
	defer u.mu.Unlock()

	u.sweep()

	held := u.held[id]
	if held == nil {
		if piece.Done && piece.Seq == nil {
			return 0, true, ErrNoUpload
		}

		if len(u.held) >= MostUploads {
			return 0, true, ErrBusy
		}

		file, err := os.CreateTemp(u.dir, "upload-*")
		if err != nil {
			return 0, false, err
		}

		held = &upload{file: file}
		u.held[id] = held
	}

	held.lastSeen = time.Now()

	if held.failed != nil {
		return 0, piece.Done, held.failed
	}

	if piece.Seq != nil {
		if *piece.Seq != held.next {
			held.failed = ErrOutOfOrder

			return 0, piece.Done, held.failed
		}

		bytes, err := base64.StdEncoding.DecodeString(piece.Data)
		if err != nil {
			held.failed = fmt.Errorf("a piece was not base64: %w", err)

			return 0, piece.Done, held.failed
		}

		if len(bytes) > ChunkSize || held.size+int64(len(bytes)) > MostUpload {
			held.failed = ErrTooLarge

			return 0, piece.Done, held.failed
		}

		if _, err := held.file.Write(bytes); err != nil {
			held.failed = err

			return 0, piece.Done, held.failed
		}

		held.size += int64(len(bytes))
		held.next++
	}

	if !piece.Done {
		return held.size, false, nil
	}

	if piece.Size == nil || *piece.Size != held.size {
		held.failed = ErrUploadSize

		return 0, true, held.failed
	}

	held.done = true

	return held.size, true, nil
}

func (u *uploads) take(id string) (string, func(), error) {
	u.mu.Lock()
	defer u.mu.Unlock()

	held := u.held[id]
	if held == nil || !held.done || held.taken || held.failed != nil {
		return "", nil, ErrNoUpload
	}

	held.taken = true

	return held.file.Name(), func() { u.forget(id) }, nil
}

func (u *uploads) forget(id string) {
	u.mu.Lock()
	defer u.mu.Unlock()

	u.drop(id)
}

func (u *uploads) drop(id string) {
	held := u.held[id]
	if held == nil {
		return
	}

	held.file.Close()
	os.Remove(held.file.Name())
	delete(u.held, id)
}

func (u *uploads) sweep() {
	for id, held := range u.held {
		if !held.taken && time.Since(held.lastSeen) > UploadKept {
			u.drop(id)
		}
	}
}

func (u *uploads) close() {
	u.mu.Lock()
	defer u.mu.Unlock()

	for id := range u.held {
		u.drop(id)
	}
}

func (s *session) put(ctx context.Context, asked *Request) {
	piece := Put{}
	if err := decode(asked.Args, &piece); err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	size, closing, err := s.uploads.put(asked.Request, piece)

	switch {
	case err != nil && closing:
		s.uploads.forget(asked.Request)
		s.refuse(ctx, asked.Request, err)
	case err != nil:
		s.Log.Warn("an upload went wrong", "request", asked.Request, "error", err)
	case closing:
		s.reply(ctx, asked.Request, Size{Size: size})
	}
}

func (s *session) extraction(ctx context.Context, asked *Request, deriving bool) {
	wanted := Extraction{}
	if err := decode(asked.Args, &wanted); err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	work, err := os.MkdirTemp(s.Work, "extract-*")
	if err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}
	defer os.RemoveAll(work)

	path, err := s.source(wanted, work)
	if err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	info, err := os.Stat(path)
	if err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	named := wanted.Filename
	if named == "" {
		named = wanted.Source.Path
	}

	in := extract.Input{
		Path: path,
		Name: filepath.Base(named),
		MIME: wanted.MIME,
		Size: info.Size(),
		Skip: map[string]bool{},
		Work: work,
		Run:  s.Runner,
		Set:  wanted.Settings,
	}

	for _, step := range wanted.Skip {
		in.Skip[step] = true
	}

	out, err := s.extracted(ctx, in, deriving)
	if err != nil {
		s.refuse(ctx, asked.Request, err)

		return
	}

	if len(out.Files) > MostFiles {
		s.refuse(ctx, asked.Request, fmt.Errorf("the extraction made more than %d files", MostFiles))

		return
	}

	sent := []Sent{}

	for _, file := range out.Files {
		held, err := s.sendFile(ctx, asked.Request, file)
		if err != nil {
			s.refuse(ctx, asked.Request, err)

			return
		}

		sent = append(sent, held)
	}

	steps := out.Steps
	if steps == nil {
		steps = map[string]extract.Step{}
	}

	s.reply(ctx, asked.Request, Extracted{Extractor: out.Extractor, Steps: steps, Dropped: out.Dropped, Files: sent})
}

func (s *session) extracted(ctx context.Context, in extract.Input, deriving bool) (*extract.Output, error) {
	if !deriving {
		return s.Extract(ctx, in)
	}

	out := &extract.Output{Extractor: "derive"}

	files, err := extract.Derive(ctx, in)
	if err != nil {
		out.Fail("derived", err)

		return out, nil
	}

	named := map[string]string{}
	for _, file := range files {
		named[file.Role] = file.Name
		out.Attach(file)
	}

	out.Set("derived", named)

	return out, nil
}

func (s *session) source(wanted Extraction, work string) (string, error) {
	if wanted.Source.Upload != "" {
		path, forget, err := s.uploads.take(wanted.Source.Upload)
		if err != nil {
			return "", err
		}

		kept := filepath.Join(work, "source"+safeExtension(wanted.Filename))
		if err := os.Rename(path, kept); err != nil {
			forget()

			return "", err
		}

		forget()

		return kept, nil
	}

	opened, err := s.Folders.Open(wanted.Source.Folder, wanted.Source.Path)
	if err != nil {
		return "", err
	}
	defer opened.Close()

	kept := filepath.Join(work, "source"+safeExtension(wanted.Source.Path))

	target, err := os.OpenFile(kept, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}

	if _, err := io.Copy(target, io.LimitReader(opened, MostUpload)); err != nil {
		target.Close()

		return "", err
	}

	return kept, target.Close()
}

func safeExtension(name string) string {
	extension := strings.ToLower(filepath.Ext(filepath.Base(name)))
	if len(extension) > 16 {
		return ""
	}

	for _, char := range extension[min(1, len(extension)):] {
		if (char < 'a' || char > 'z') && (char < '0' || char > '9') {
			return ""
		}
	}

	return extension
}

func (s *session) sendFile(ctx context.Context, of string, file extract.File) (Sent, error) {
	opened, err := os.Open(file.Path)
	if err != nil {
		return Sent{}, err
	}
	defer opened.Close()

	id := uuid()
	buffer := make([]byte, s.Chunk)
	size := int64(0)

	for seq := 0; ; seq++ {
		count, err := io.ReadFull(opened, buffer)

		if count > 0 {
			chunk := Chunk{Request: id, Of: of, Seq: seq, Data: base64.StdEncoding.EncodeToString(buffer[:count])}
			if err := s.conn.Perform(ctx, "chunk", chunk); err != nil {
				return Sent{}, err
			}

			size += int64(count)
		}

		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			break
		}

		if err != nil {
			return Sent{}, err
		}
	}

	return Sent{Role: file.Role, Name: file.Name, MIME: file.MIME, Size: size, RequestFile: id, At: file.At}, nil
}

func uuid() string {
	held := make([]byte, 16)
	rand.Read(held)
	held[6] = held[6]&0x0f | 0x40
	held[8] = held[8]&0x3f | 0x80

	return fmt.Sprintf("%x-%x-%x-%x-%x", held[0:4], held[4:6], held[6:8], held[8:10], held[10:16])
}
