package link

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/xixo/xixo/link/internal/dial"
	"github.com/xixo/xixo/link/internal/digests"
	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/folders"
)

const (
	MostUpload  = 4 << 30
	MostWork    = 12 << 30
	MostFiles   = 256
	fetchedPace = 256 << 10
	verbExtract = "extract"
	verbDerive  = "derive"
)

var (
	ErrNoUpload   = errors.New("an upload is named by a uuid")
	ErrUploadSize = errors.New("the upload's size does not match what arrived")
	ErrTooLarge   = errors.New("xixo link takes a copy of at most 4 GB, so only the machine that shares a larger file reads it")
	ErrShifted    = errors.New("the file changed while xixo link extracted it, so xixo link sent nothing; ask again once it settles")
	uploadClient  = dial.Fetcher()
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

type Digest struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Extracted struct {
	Digest
	Extractor string                  `json:"extractor"`
	Steps     map[string]extract.Step `json:"steps"`
	Dropped   map[string]string       `json:"dropped,omitempty"`
	Files     []Sent                  `json:"files"`
}

func (a *Link) extraction(ctx context.Context, asked *Request, deriving bool) {
	wanted := Extraction{}
	if err := decode(asked.Args, &wanted); err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	work, err := os.MkdirTemp(a.Work, "extract-*")
	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}
	defer os.RemoveAll(work)

	held, err := a.source(ctx, wanted, work)
	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}
	defer held.close()

	named := wanted.Filename
	if named == "" {
		named = wanted.Source.Path
	}

	in := extract.Input{
		Path: held.path,
		Name: filepath.Base(named),
		MIME: wanted.MIME,
		Size: held.digest.Size,
		Skip: map[string]bool{},
		Work: work,
		Run:  extract.Reading(extract.Within(a.Runner, work, MostWork), held.from),
		Set:  wanted.Settings,
	}

	for _, step := range wanted.Skip {
		in.Skip[step] = true
	}

	out, err := a.extracted(ctx, in, deriving)
	if err == nil {
		err = held.settled()
	}

	if err != nil {
		a.refuse(ctx, asked.Request, err)

		return
	}

	if len(out.Files) > MostFiles {
		a.refuse(ctx, asked.Request, fmt.Errorf("the extraction made more than %d files", MostFiles))

		return
	}

	sent := []Sent{}

	for _, file := range out.Files {
		held, err := a.sendFile(ctx, asked.Request, file)
		if err != nil {
			a.refuse(ctx, asked.Request, err)

			return
		}

		sent = append(sent, held)
	}

	steps := out.Steps
	if steps == nil {
		steps = map[string]extract.Step{}
	}

	a.reply(ctx, asked.Request, Extracted{Digest: held.digest, Extractor: out.Extractor, Steps: steps, Dropped: out.Dropped, Files: sent})
}

func (a *Link) extracted(ctx context.Context, in extract.Input, deriving bool) (*extract.Output, error) {
	if !deriving {
		return a.Extract(ctx, in)
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

type sourced struct {
	path   string
	digest Digest
	from   *extract.Source
	opened *folders.Opened
	before fs.FileInfo
}

func (s *sourced) settled() error {
	if s.from == nil {
		return nil
	}

	after, err := s.opened.Stat()
	if err != nil {
		return err
	}

	if !unchanged(s.before, after) {
		return ErrShifted
	}

	for _, read := range s.from.Reads {
		there, err := os.Stat(read)
		if err != nil || !os.SameFile(there, after) || !unchanged(s.before, there) {
			return ErrShifted
		}
	}

	return nil
}

func unchanged(before, after fs.FileInfo) bool {
	held, known := digests.Of(before)
	now, _ := digests.Of(after)

	if known {
		return held == now
	}

	return before.Size() == after.Size() && before.ModTime().Equal(after.ModTime())
}

func (s *sourced) close() {
	if s.opened == nil {
		return
	}

	s.opened.Forget()
	s.opened.Close()
}

func (a *Link) source(ctx context.Context, wanted Extraction, work string) (*sourced, error) {
	if wanted.Source.Upload != "" {
		path, digest, err := a.fetch(ctx, wanted, work)
		if err != nil {
			return nil, err
		}

		return &sourced{path: path, digest: digest}, nil
	}

	opened, err := a.Folders.Open(wanted.Source.Folder, wanted.Source.Path)
	if err != nil {
		return nil, err
	}

	named := wanted.Filename
	if named == "" {
		named = wanted.Source.Path
	}

	if !extract.Copies(wanted.MIME, filepath.Base(named)) {
		held, err := a.inPlace(ctx, opened, work, safeExtension(wanted.Source.Path))
		if !errors.Is(err, extract.ErrNotInPlace) {
			if err != nil {
				opened.Close()
			}

			return held, err
		}
	}

	defer opened.Close()

	path, digest, err := a.copySource(ctx, opened, work, safeExtension(wanted.Source.Path))
	if err != nil {
		return nil, err
	}

	return &sourced{path: path, digest: digest}, nil
}

func (a *Link) inPlace(ctx context.Context, opened *folders.Opened, work, extension string) (*sourced, error) {
	digest, err := a.digestOf(ctx, opened)
	if err != nil {
		return nil, err
	}

	from, err := extract.InPlace(opened.File(), work, extension)
	if err != nil {
		return nil, err
	}

	return &sourced{path: from.Path, digest: digest, from: from, opened: opened, before: opened.Info}, nil
}

func (a *Link) copySource(ctx context.Context, opened *folders.Opened, work, extension string) (string, Digest, error) {
	if opened.Size > MostUpload {
		return "", Digest{}, ErrTooLarge
	}

	defer opened.Forget()

	kept := filepath.Join(work, "source"+extension)

	digest, err := copied(ctx, kept, io.LimitReader(opened, MostUpload+1))
	if err != nil {
		return "", Digest{}, err
	}

	if digest.Size > MostUpload {
		return "", Digest{}, ErrTooLarge
	}

	a.remember(opened, digest)

	return kept, digest, nil
}

func (a *Link) remember(opened *folders.Opened, digest Digest) {
	if a.Digests == nil {
		return
	}

	before, known := digests.Of(opened.Info)
	if !known || before.Size != digest.Size {
		return
	}

	info, err := opened.Stat()
	if err != nil {
		return
	}

	if after, _ := digests.Of(info); after == before {
		a.Digests.Note(before, digest.SHA256)
	}
}

func copied(ctx context.Context, kept string, from io.Reader) (Digest, error) {
	target, err := os.OpenFile(kept, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return Digest{}, err
	}

	hashed := sha256.New()
	written, err := io.Copy(io.MultiWriter(target, hashed), folders.Halting(ctx, from))

	if closed := target.Close(); err == nil {
		err = closed
	}

	if err != nil {
		return Digest{}, err
	}

	return Digest{SHA256: hex.EncodeToString(hashed.Sum(nil)), Size: written}, nil
}

func digested(ctx context.Context, from io.Reader) (Digest, error) {
	hashed := sha256.New()

	written, err := io.Copy(hashed, folders.Halting(ctx, from))
	if err != nil {
		return Digest{}, err
	}

	return Digest{SHA256: hex.EncodeToString(hashed.Sum(nil)), Size: written}, nil
}

func (a *Link) fetch(ctx context.Context, wanted Extraction, work string) (string, Digest, error) {
	if wanted.Size < 0 || wanted.Size > MostUpload {
		return "", Digest{}, ErrTooLarge
	}

	kept := filepath.Join(work, "source"+safeExtension(wanted.Filename))

	ctx, cancel := context.WithTimeout(ctx, fetchedWithin(wanted.Size))
	defer cancel()

	response, err := a.upload(ctx, wanted.Source.Upload, wanted.Size)
	if err != nil {
		return "", Digest{}, err
	}
	defer response.Body.Close()

	digest, err := copied(ctx, kept, io.LimitReader(response.Body, wanted.Size+1))
	if err != nil {
		return "", Digest{}, err
	}

	if digest.Size != wanted.Size {
		return "", Digest{}, ErrUploadSize
	}

	return kept, digest, nil
}

func (a *Link) upload(ctx context.Context, upload string, size int64) (*http.Response, error) {
	if !uploadName.MatchString(upload) {
		return nil, ErrNoUpload
	}

	target := strings.TrimSuffix(a.Xixo, "/") + "/link/uploads/" + upload
	nonce := ""

	for attempt := 0; ; attempt++ {
		response, err := a.fetched(ctx, target, nonce)
		if err != nil {
			return nil, err
		}

		offered := response.Header.Get("DPoP-Nonce")
		if response.StatusCode == http.StatusUnauthorized && attempt == 0 && offered != "" && offered != nonce {
			response.Body.Close()
			nonce = offered

			continue
		}

		if response.StatusCode != http.StatusOK {
			response.Body.Close()

			return nil, fmt.Errorf("xixo answered the upload with %s", response.Status)
		}

		if response.ContentLength >= 0 && response.ContentLength != size {
			response.Body.Close()

			return nil, ErrUploadSize
		}

		return response, nil
	}
}

func (a *Link) fetched(ctx context.Context, target, nonce string) (*http.Response, error) {
	_, token, err := a.wire.current(ctx)
	if err != nil {
		return nil, err
	}

	proof, err := a.DPoP.Proof(http.MethodGet, target, token.AccessToken, nonce)
	if err != nil {
		return nil, err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}

	request.Header.Set("Authorization", "DPoP "+token.AccessToken)
	request.Header.Set("DPoP", proof)

	return uploadClient.Do(request)
}

func fetchedWithin(size int64) time.Duration {
	return 2*time.Minute + time.Duration(size/fetchedPace)*time.Second
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

func (a *Link) sendFile(ctx context.Context, of string, file extract.File) (Sent, error) {
	opened, err := os.Open(file.Path)
	if err != nil {
		return Sent{}, err
	}
	defer opened.Close()

	id := uuid()
	buffer := make([]byte, a.Chunk)
	size := int64(0)
	source := folders.Halting(ctx, opened)

	for seq := 0; ; seq++ {
		count, err := io.ReadFull(source, buffer)

		if count > 0 {
			chunk := Chunk{Request: id, Of: of, Seq: seq, Data: base64.StdEncoding.EncodeToString(buffer[:count])}
			if err := a.wire.perform(ctx, "chunk", chunk); err != nil {
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
