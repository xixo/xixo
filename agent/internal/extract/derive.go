package extract

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	Thumbnail   = "thumbnail"
	Preview     = "preview"
	posterAt    = "00:00:01"
	wave        = "0xc9a86a"
	ground      = "0x1b2024"
	waveSeconds = 3600
	waveNarrow  = 1000
	waveWide    = 2000
	rawWidest   = 1024
	deriveTime  = 5 * time.Minute
)

var ErrUnrendered = errors.New("nothing could be rendered")

type deriving struct {
	ctx   context.Context
	in    Input
	role  string
	width int
	dir   string
}

func Derive(ctx context.Context, in Input) ([]File, error) {
	if !Thumbnailable(in.MIME) {
		return nil, fmt.Errorf("nothing to render for a %s", in.MIME)
	}

	set := in.Set.Settled()
	files := []File{}

	for _, role := range []string{Thumbnail, Preview} {
		width := set.Thumbnail
		if role == Preview {
			width = set.Preview
		}

		dir, err := os.MkdirTemp(in.Work, role)
		if err != nil {
			return nil, err
		}

		made, err := (&deriving{ctx: ctx, in: in, role: role, width: width, dir: dir}).render()
		if err != nil {
			return nil, err
		}

		kept := filepath.Join(in.Work, role+".jpg")
		if err := os.Rename(made, kept); err != nil {
			return nil, err
		}

		files = append(files, File{Role: role, Name: role + ".jpg", MIME: JPEG, Path: kept})
	}

	return files, nil
}

func (d *deriving) hires() bool { return d.role == Preview }

func (d *deriving) bounds() string {
	if d.hires() {
		return fmt.Sprintf("%dx%d>", d.width, d.width)
	}

	return fmt.Sprintf("%dx>", d.width)
}

func (d *deriving) out() string {
	return filepath.Join(d.dir, "out.jpg")
}

func (d *deriving) run(program string, args ...string) error {
	_, err := d.in.Run.Run(d.ctx, deriveTime, program, args...)

	return err
}

func (d *deriving) render() (string, error) {
	switch {
	case d.in.MIME == Page:
		return d.fromPage()
	case d.in.MIME == PDF:
		return d.fromPDF()
	case Video(d.in.MIME):
		return d.fromVideo()
	case Audio(d.in.MIME):
		return d.fromAudio()
	default:
		return d.fromImage()
	}
}

func (d *deriving) fromImage() (string, error) {
	source := d.in.Path

	if Raw(d.in.Name) {
		viewable, err := RawPreview(d.ctx, d.in.Run, d.in.Path, d.dir)
		if err != nil {
			return "", err
		}

		source = viewable
	}

	if err := d.run("vipsthumbnail", source, "--size", d.bounds(), "-o", d.out()+"[Q=80]"); err != nil {
		return "", err
	}

	return d.made(d.out())
}

func (d *deriving) fromPage() (string, error) {
	args := []string{d.in.Path, "--size"}

	if d.hires() {
		args = append(args, fmt.Sprintf("%dx>", d.width))
	} else {
		args = append(args, fmt.Sprintf("%dx%d", d.width, d.width), "--smartcrop", "low")
	}

	if err := d.run("vipsthumbnail", append(args, "-o", d.out()+"[Q=80]")...); err != nil {
		return "", err
	}

	return d.made(d.out())
}

func (d *deriving) fromVideo() (string, error) {
	frame := filepath.Join(d.dir, "frame.png")

	_ = d.run("ffmpeg", "-v", "error", "-y", "-ss", posterAt, "-i", d.in.Path, "-frames:v", "1", frame)

	if !sized(frame) {
		if err := d.run("ffmpeg", "-v", "error", "-y", "-i", d.in.Path, "-frames:v", "1", frame); err != nil {
			return "", err
		}
	}

	if !sized(frame) {
		return "", fmt.Errorf("ffmpeg rendered no frame of %s", d.in.Name)
	}

	if err := d.run("vipsthumbnail", frame, "--size", d.bounds(), "-o", d.out()+"[Q=80]"); err != nil {
		return "", err
	}

	return d.made(d.out())
}

func (d *deriving) fromAudio() (string, error) {
	wide := d.waveWidth()
	shape := fmt.Sprintf("%dx%d", wide, wide/3)
	graph := fmt.Sprintf("[0:a]aformat=channel_layouts=mono,showwavespic=s=%s:scale=sqrt:colors=%s[wave];"+
		"color=c=%s:s=%s[ground];[ground][wave]overlay=format=auto", shape, wave, ground, shape)

	err := d.run("ffmpeg", "-v", "error", "-y", "-t", strconv.Itoa(waveSeconds), "-i", d.in.Path,
		"-filter_complex", graph, "-frames:v", "1", "-q:v", "3", d.out())
	if err != nil {
		return "", err
	}

	return d.made(d.out())
}

func (d *deriving) waveWidth() int {
	out, _ := d.in.Run.Run(d.ctx, time.Minute, "ffprobe", "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", d.in.Path)
	seconds, _ := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	rendered := math.Max(0, math.Min(seconds, waveSeconds))
	spread := float64(waveWide - waveNarrow)

	return max(waveNarrow, min(waveWide, int(math.Round(waveNarrow+(rendered/waveSeconds)*spread))))
}

func (d *deriving) fromPDF() (string, error) {
	prefix := filepath.Join(d.dir, "page")
	scale := []string{"-scale-to-x", strconv.Itoa(d.width), "-scale-to-y", "-1"}

	if d.hires() {
		scale = []string{"-scale-to", strconv.Itoa(d.width)}
	}

	args := append([]string{"-jpeg", "-r", "72", "-f", "1", "-l", "1"}, scale...)
	if err := d.run("pdftoppm", append(args, d.in.Path, prefix)...); err != nil {
		return "", err
	}

	found, _ := filepath.Glob(prefix + "*.jpg")
	if len(found) == 0 {
		return "", errors.New("pdftoppm rendered no page")
	}

	return found[0], nil
}

func (d *deriving) made(path string) (string, error) {
	if !sized(path) {
		return "", fmt.Errorf("%w for %s", ErrUnrendered, d.in.Name)
	}

	return path, nil
}

func RawPreview(ctx context.Context, run Runner, path, dir string) (string, error) {
	copied := filepath.Join(dir, "raw"+filepath.Ext(path))
	if err := os.Link(path, copied); err != nil {
		if err := copyFile(path, copied); err != nil {
			return "", err
		}
	}

	if _, err := run.Run(ctx, deriveTime, "simple_dcraw", "-e", copied); err == nil {
		if found, _ := filepath.Glob(copied + ".thumb.*"); len(found) > 0 && wideEnough(ctx, run, found[0]) {
			return found[0], nil
		}
	}

	if _, err := run.Run(ctx, deriveTime, "simple_dcraw", "-T", copied); err != nil {
		return "", fmt.Errorf("%s carries no image simple_dcraw could read: %w", filepath.Base(path), err)
	}

	developed := copied + ".tiff"
	if !sized(developed) {
		return "", fmt.Errorf("%s carries no image simple_dcraw could read", filepath.Base(path))
	}

	return developed, nil
}

func wideEnough(ctx context.Context, run Runner, path string) bool {
	out, err := run.Run(ctx, time.Minute, "vipsheader", "-f", "width", path)
	if err != nil {
		return false
	}

	width, _ := strconv.Atoi(strings.TrimSpace(string(out)))

	return width >= rawWidest
}

func sized(path string) bool {
	info, err := os.Stat(path)

	return err == nil && info.Size() > 0
}

func copyFile(from, to string) error {
	source, err := os.Open(from)
	if err != nil {
		return err
	}
	defer source.Close()

	target, err := os.OpenFile(to, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}

	if _, err := io.Copy(target, source); err != nil {
		target.Close()

		return err
	}

	return target.Close()
}
