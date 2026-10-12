package agent

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	MostUpload  = 4 << 30
	MostFiles   = 256
	verbExtract = "extract"
	verbDerive  = "derive"
)

var (
	ErrNoUpload   = errors.New("an upload is named by a uuid")
	ErrUploadSize = errors.New("the upload's size does not match what arrived")
	ErrTooLarge   = errors.New("the upload is larger than the agent keeps")
	uploadClient  = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	uploadName    = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

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

	path, err := s.source(ctx, wanted, work)
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

func (s *session) source(ctx context.Context, wanted Extraction, work string) (string, error) {
	if wanted.Source.Upload != "" {
		return s.fetch(ctx, wanted, work)
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

func (s *session) fetch(ctx context.Context, wanted Extraction, work string) (string, error) {
	if !uploadName.MatchString(wanted.Source.Upload) {
		return "", ErrNoUpload
	}

	if wanted.Size < 0 || wanted.Size > MostUpload {
		return "", ErrTooLarge
	}

	target := strings.TrimSuffix(s.Xixo, "/") + "/agent/uploads/" + wanted.Source.Upload
	kept := filepath.Join(work, "source"+safeExtension(wanted.Filename))
	nonce := ""

	for attempt := 0; ; attempt++ {
		response, err := s.fetched(ctx, target, nonce)
		if err != nil {
			return "", err
		}

		offered := response.Header.Get("DPoP-Nonce")
		if response.StatusCode == http.StatusUnauthorized && attempt == 0 && offered != "" && offered != nonce {
			response.Body.Close()
			nonce = offered

			continue
		}

		err = keep(response, kept, wanted.Size)
		response.Body.Close()

		return kept, err
	}
}

func (s *session) fetched(ctx context.Context, target, nonce string) (*http.Response, error) {
	proof, err := s.DPoP.Proof(http.MethodGet, target, s.token.AccessToken, nonce)
	if err != nil {
		return nil, err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}

	request.Header.Set("Authorization", "DPoP "+s.token.AccessToken)
	request.Header.Set("DPoP", proof)

	return uploadClient.Do(request)
}

func keep(response *http.Response, kept string, size int64) error {
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("xixo answered the upload with %s", response.Status)
	}

	if response.ContentLength >= 0 && response.ContentLength != size {
		return ErrUploadSize
	}

	target, err := os.OpenFile(kept, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}

	written, err := io.Copy(target, io.LimitReader(response.Body, size+1))
	if closed := target.Close(); err == nil {
		err = closed
	}

	if err != nil {
		return err
	}

	if written != size {
		return ErrUploadSize
	}

	return nil
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
