package rich

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/emersion/go-message"
	_ "github.com/emersion/go-message/charset"
	"github.com/emersion/go-message/mail"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	Earlier         = "Earlier in the thread"
	mostMessage     = 256 << 20
	mostHeaderBytes = 1 << 20
	mostHeaderValue = 2_000
	mostDepth       = 10
	mostParts       = 500
	mostChildren    = 100
	mostChild       = 256 << 20
	mostChildBytes  = 1 << 30
	mostBody        = 16 << 20
)

var shown = []string{"from", "to", "cc", "date", "subject"}

var unsafeName = regexp.MustCompile(`[^\w.\- ]+`)

type Email struct{}

func (Email) Name() string { return "email" }

func (Email) Handles(mime, name string) bool { return mime == "message/rfc822" }

func (Email) Needs() []string { return nil }

type Attachment struct {
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
	Size        int64  `json:"size"`
}

type Thread struct {
	IDs []string `json:"ids"`
}

type reading struct {
	in       extract.Input
	out      *extract.Output
	plain    *string
	html     *string
	attached []Attachment
	parts    int
	written  int64
	children int
}

func (Email) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{Extractor: "email"}

	raw, err := os.ReadFile(in.Path)
	if err != nil {
		return nil, err
	}

	if len(raw) > mostMessage {
		out.Drop("message", fmt.Sprintf("only the first %s bytes of the message were read", extract.Delimited(mostMessage)))
		raw = raw[:mostMessage]
	}

	entity, err := message.ReadWithOptions(bytes.NewReader(raw), &message.ReadOptions{MaxHeaderBytes: mostHeaderBytes})
	if err != nil && !message.IsUnknownCharset(err) && !message.IsUnknownEncoding(err) {
		return headless(out, raw), nil
	}

	r := &reading{in: in, out: out, attached: []Attachment{}}
	header := mail.Header{Header: entity.Header}

	headers := headersOf(header)
	out.Set("headers", headers)
	out.Set("thread", threadOf(header))

	if err := r.walk(ctx, entity, 0); err != nil {
		out.Drop("parts", err.Error())
	}

	out.Set("attachments", r.attached)

	text, outline := writtenOut(headers, r.body(headers["subject"]))
	out.Set("outline", outline)
	out.Set("text", out.Capped(text))

	return out, nil
}

func headless(out *extract.Output, raw []byte) *extract.Output {
	text := strings.TrimSpace(valid(string(raw)))

	out.Set("headers", map[string]string{})
	out.Set("thread", Thread{IDs: []string{}})
	out.Set("attachments", []Attachment{})
	out.Set("outline", []extract.Section{{Name: "Message from its sender", From: 0}})
	out.Set("text", out.Capped(text))

	return out
}

func headersOf(header mail.Header) map[string]string {
	held := map[string]string{}

	for _, name := range []string{"from", "to", "cc"} {
		if said := addresses(header, name); said != "" {
			held[name] = said
		}
	}

	if subject, err := header.Subject(); err == nil && strings.TrimSpace(subject) != "" {
		held["subject"] = extract.Truncate(extract.Squish(valid(subject)), mostHeaderValue)
	} else if raw := header.Get("Subject"); raw != "" {
		held["subject"] = extract.Truncate(extract.Squish(valid(raw)), mostHeaderValue)
	}

	if date, err := header.Date(); err == nil && !date.IsZero() {
		held["date"] = date.Format(time.RFC3339)
	} else if raw := header.Get("Date"); raw != "" {
		held["date"] = extract.Truncate(extract.Squish(valid(raw)), 200)
	}

	if id, err := header.MessageID(); err == nil && id != "" {
		held["message_id"] = extract.Truncate(id, 998)
	}

	return held
}

func addresses(header mail.Header, name string) string {
	list, err := header.AddressList(name)
	if err != nil || len(list) == 0 {
		raw, _ := header.Text(name)

		return extract.Truncate(extract.Squish(valid(raw)), mostHeaderValue)
	}

	said := make([]string, 0, len(list))

	for _, address := range list {
		named := extract.Squish(valid(address.Name))
		if named == "" {
			said = append(said, address.Address)
		} else {
			said = append(said, fmt.Sprintf("%s <%s>", named, address.Address))
		}
	}

	return extract.Truncate(strings.Join(said, ", "), mostHeaderValue)
}

func threadOf(header mail.Header) Thread {
	ids := []string{}
	seen := map[string]bool{}

	add := func(id string) {
		id = strings.TrimSpace(strings.Trim(id, "<> "))
		if id != "" && !seen[id] && len(ids) < 200 {
			seen[id] = true
			ids = append(ids, extract.Truncate(id, 998))
		}
	}

	if id, err := header.MessageID(); err == nil {
		add(id)
	}

	for _, field := range []string{"In-Reply-To", "References"} {
		if listed, err := header.MsgIDList(field); err == nil {
			for _, id := range listed {
				add(id)
			}
		}
	}

	return Thread{IDs: ids}
}

func (r *reading) walk(ctx context.Context, entity *message.Entity, depth int) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	if depth > mostDepth {
		return fmt.Errorf("parts nested deeper than %d levels were not read", mostDepth)
	}

	r.parts++
	if r.parts > mostParts {
		return fmt.Errorf("only the first %d parts of the message were read", mostParts)
	}

	kind, params, _ := entity.Header.ContentType()
	disposition, _, _ := entity.Header.ContentDisposition()
	attachment := mail.AttachmentHeader{Header: entity.Header}
	filename, _ := attachment.Filename()

	if filename == "" && params["name"] != "" {
		filename = params["name"]
	}

	if multipart := entity.MultipartReader(); multipart != nil && filename == "" {
		for {
			part, err := multipart.NextPart()
			if errors.Is(err, io.EOF) {
				return nil
			}

			if err != nil && !message.IsUnknownCharset(err) && !message.IsUnknownEncoding(err) {
				return fmt.Errorf("a part of the message could not be read: %s", extract.Truncate(err.Error(), 200))
			}

			if err := r.walk(ctx, part, depth+1); err != nil {
				return err
			}
		}
	}

	if kind == "message/rfc822" && filename == "" {
		filename = "attached message.eml"
	}

	if filename != "" || disposition == "attachment" {
		return r.child(entity, filename, kind)
	}

	switch {
	case kind == "text/plain" && r.plain == nil:
		said := readText(entity.Body)
		r.plain = &said
	case kind == "text/html" && r.html == nil:
		said := extract.Markup(readText(entity.Body))
		r.html = &said
	case kind == "" && r.plain == nil:
		said := readText(entity.Body)
		r.plain = &said
	}

	return nil
}

func readText(body io.Reader) string {
	held, _ := io.ReadAll(io.LimitReader(body, mostBody))

	return valid(string(held))
}

func (r *reading) child(entity *message.Entity, filename, kind string) error {
	if filename == "" {
		filename = "attachment"
	}

	filename = extract.Truncate(extract.Squish(valid(filename)), 255)
	if kind == "" {
		kind = "application/octet-stream"
	}

	if r.children >= mostChildren {
		r.out.Drop("attachments", fmt.Sprintf("only the first %d attachments were kept", mostChildren))
		_, err := io.Copy(io.Discard, entity.Body)

		return discarded(err)
	}

	room := min(int64(mostChild), int64(mostChildBytes)-r.written)
	if room <= 0 {
		r.out.Drop("attachments", fmt.Sprintf("attachments past the first %s bytes were not kept", extract.Delimited(mostChildBytes)))

		return nil
	}

	r.children++
	path := filepath.Join(r.in.Work, fmt.Sprintf("child-%d%s", r.children, safeExt(filename)))

	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}

	size, err := io.Copy(file, io.LimitReader(entity.Body, room+1))
	closed := file.Close()

	if err := errors.Join(discarded(err), closed); err != nil {
		os.Remove(path)

		return fmt.Errorf("%s could not be read: %s", filename, extract.Truncate(err.Error(), 200))
	}

	if size > room {
		os.Remove(path)
		r.out.Drop("attachments", fmt.Sprintf("%s is larger than %s bytes and was not kept", filename, extract.Delimited(int(room))))

		return nil
	}

	r.written += size
	r.attached = append(r.attached, Attachment{Filename: filename, ContentType: kind, Size: size})
	r.out.Attach(extract.File{Role: "child", Name: filename, MIME: kind, Path: path})

	return nil
}

func discarded(err error) error {
	if err == nil || message.IsUnknownCharset(err) || message.IsUnknownEncoding(err) {
		return nil
	}

	return err
}

func safeExt(filename string) string {
	ext := unsafeName.ReplaceAllString(filepath.Ext(filename), "")
	if len(ext) > 16 {
		return ""
	}

	return ext
}

func (r *reading) body(subject string) string {
	text := ""

	switch {
	case r.plain != nil && strings.TrimSpace(*r.plain) != "":
		text = *r.plain
	case r.html != nil:
		text = *r.html
	case r.plain != nil:
		text = *r.plain
	}

	text = strings.ReplaceAll(text, "\r\n", "\n")

	parts := []string{}
	for _, part := range []string{subject, text} {
		if part != "" {
			parts = append(parts, part)
		}
	}

	return strings.TrimSpace(strings.Join(parts, "\n\n"))
}

func writtenOut(headers map[string]string, body string) (string, []extract.Section) {
	said := Quoted(body)

	lines := []string{}
	for _, name := range shown {
		if value := headers[name]; value != "" {
			lines = append(lines, strings.ToUpper(name[:1])+name[1:]+": "+value)
		}
	}

	head := strings.Join(nonEmpty(strings.Join(lines, "\n"), said.Fresh), "\n\n")

	sender := headers["from"]
	if sender == "" {
		sender = "its sender"
	}

	outline := []extract.Section{{Name: "Message from " + extract.Truncate(sender, 200), From: 0}}

	if said.Earlier == "" {
		return head, outline
	}

	outline = append(outline, extract.Section{Name: Earlier, From: length(head) + 2})

	return head + "\n\n## " + Earlier + "\n\n" + said.Earlier, outline
}

func init() {
	extract.Register(Email{})
}
