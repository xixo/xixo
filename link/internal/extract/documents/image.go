package documents

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/xixo/xixo/link/internal/extract"
)

const (
	LocatedBy    = "exiftool"
	FrameWidth   = 768
	RawMinimum   = 1024
	RawImageMIME = "image/x-dcraw"
)

var (
	animatable = map[string]bool{"image/gif": true, "image/webp": true, "image/apng": true}
	rawFormats = map[string]bool{}
)

func init() {
	for _, ext := range strings.Fields(`3fr ari arw cap cr2 cr3 crw dcr dng erf fff iiq k25 kdc mdc mos mrw
		nef nrw orf ori pef pxn raf rw2 rwl sr2 srf srw x3f`) {
		rawFormats[ext] = true
	}
}

func IsRaw(name string) bool {
	return rawFormats[strings.TrimPrefix(strings.ToLower(filepath.Ext(name)), ".")]
}

type Image struct{}

func (Image) Name() string { return "image" }

func (Image) Handles(mime, _ string) bool { return strings.HasPrefix(mime, "image/") }

func (Image) Needs() []string {
	return []string{"vipsheader", "vips", "exiftool", "tesseract", "simple_dcraw"}
}

func (Image) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	s := begin(ctx, in, "image")

	path := in.Path
	if IsRaw(in.Name) {
		developed, err := s.viewableRaw(in.Path)
		if err != nil {
			if s.wanted("dimensions") {
				result, tagErr := s.taggedDimensions(in.Path)
				if tagErr != nil {
					tagErr = err
				}
				s.keep("dimensions", "", result, tagErr)
			}
			if s.wanted("location") {
				result, err := s.location(in.Path)
				s.keep("location", LocatedBy, result, err)
			}
			return s.finish(), ctx.Err()
		}
		path = developed
	}

	measured, measureErr := s.dimensions(path)
	if s.wanted("dimensions") {
		s.keep("dimensions", "", measured, measureErr)
	}
	if s.wanted("deviation") {
		result, err := s.deviation(path, measured)
		s.keep("deviation", "", result, err)
	}

	frames := 0
	if animatable[in.MIME] {
		frames = s.frameCount(path)
		s.keep("frames", "", frames, nil)
	}

	if s.wanted("location") {
		result, err := s.location(in.Path)
		s.keep("location", LocatedBy, result, err)
	}

	if s.wanted("ocr") {
		text, err := s.ocr(path)
		s.keep("ocr", "", s.capped(strings.TrimSpace(text)), err)
	}

	if frames > 1 {
		s.sampleFrames(path, frames)
	}

	return s.finish(), ctx.Err()
}

func (s *session) header(path, field string) (int, error) {
	said, err := s.run(Patience, "vipsheader", "-f", field, path)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(said))
}

func (s *session) frameCount(path string) int {
	count, err := s.header(path, "n-pages")
	if err != nil || count < 1 {
		return 1
	}
	return count
}

func (s *session) dimensions(path string) (map[string]int, error) {
	width, err := s.header(path, "width")
	if err != nil {
		return nil, err
	}
	height, err := s.header(path, "height")
	if err != nil {
		return nil, err
	}
	return map[string]int{"width": width, "height": height}, nil
}

func (s *session) taggedDimensions(path string) (map[string]int, error) {
	said, err := s.run(Patience, "exiftool", "-j", "-n", "-ImageWidth", "-ImageHeight", path)
	if err != nil {
		return nil, err
	}
	var tagged []struct {
		ImageWidth  int
		ImageHeight int
	}
	if err := json.Unmarshal([]byte(said), &tagged); err != nil {
		return nil, err
	}
	if len(tagged) == 0 || tagged[0].ImageWidth <= 0 || tagged[0].ImageHeight <= 0 {
		return nil, errors.New("the image names no width and height")
	}
	return map[string]int{"width": tagged[0].ImageWidth, "height": tagged[0].ImageHeight}, nil
}

func (s *session) deviation(path string, measured map[string]int) (float64, error) {
	if measured != nil && measured["width"]*measured["height"] < 2 {
		return 0, nil
	}
	said, err := s.run(Patience, "vips", "deviate", path)
	if err != nil {
		return 0, err
	}
	spread, err := strconv.ParseFloat(strings.TrimSpace(said), 64)
	if err != nil {
		return 0, err
	}
	format, _ := s.run(Patience, "vipsheader", "-f", "format", path)
	return round6(spread / sampleRange(strings.TrimSpace(format))), nil
}

func sampleRange(format string) float64 {
	format = strings.ToUpper(format)
	switch {
	case strings.Contains(format, "DPCOMPLEX"), strings.Contains(format, "COMPLEX"),
		strings.Contains(format, "DOUBLE"), strings.Contains(format, "FLOAT"):
		return 1.0 / 255
	case strings.Contains(format, "UINT"), strings.Contains(format, "_INT"):
		return 16843009
	case strings.Contains(format, "USHORT"), strings.Contains(format, "SHORT"):
		return 257
	}
	return 1
}

func (s *session) location(path string) (map[string]float64, error) {
	said, err := s.run(Glance, "exiftool", "-json", "-n", "-Composite:GPSLatitude", "-Composite:GPSLongitude", path)
	var found []map[string]any
	if jsonErr := json.Unmarshal([]byte(said), &found); jsonErr != nil {
		if err != nil {
			return nil, err
		}
		return nil, nil
	}
	if len(found) == 0 {
		return nil, nil
	}
	latitude, okLat := found[0]["GPSLatitude"].(float64)
	longitude, okLon := found[0]["GPSLongitude"].(float64)
	if !okLat || !okLon || (latitude == 0 && longitude == 0) {
		return nil, nil
	}
	return map[string]float64{"latitude": round6(latitude), "longitude": round6(longitude)}, nil
}

func round6(v float64) float64 {
	return math.Round(v*1e6) / 1e6
}

func (s *session) ocr(path string) (string, error) {
	said, err := s.run(Patience, "tesseract", path, "stdout")
	if err == nil {
		return said, nil
	}
	flat := filepath.Join(s.in.Work, "ocr.png")
	if _, convertErr := s.run(Patience, "vips", "copy", path+"[0]", flat); convertErr != nil {
		return "", err
	}
	return s.run(Patience, "tesseract", flat, "stdout")
}

func Picked(frames, most, share int) []int {
	if frames < 1 {
		return nil
	}
	shown := int(math.Ceil(float64(frames*share) / 100.0))
	shown = min(max(shown, 1), min(most, frames))
	var picked []int
	seen := map[int]bool{}
	for at := 0; at < shown; at++ {
		page := at * frames / shown
		if !seen[page] {
			seen[page] = true
			picked = append(picked, page)
		}
	}
	return picked
}

func (s *session) sampleFrames(path string, frames int) {
	set := s.in.Set.Settled()
	most, share := set.Frames, set.Share
	dir := filepath.Join(s.in.Work, "frames")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	for _, page := range Picked(frames, most, share) {
		still := filepath.Join(dir, fmt.Sprintf("frame-%d.jpg", page))
		if _, err := s.run(Patience, "vips", "thumbnail", fmt.Sprintf("%s[page=%d]", path, page), still, strconv.Itoa(FrameWidth)); err != nil {
			s.leave("frames", fmt.Sprintf("frame %d of %d could not be drawn", page+1, frames))
			continue
		}
		s.out.Files = append(s.out.Files, extract.File{
			Role: "frame",
			Name: filepath.Base(still),
			MIME: "image/jpeg",
			Path: still,
		})
	}
}

func (s *session) viewableRaw(source string) (string, error) {
	dir, err := os.MkdirTemp(s.in.Work, "raw-")
	if err != nil {
		return "", err
	}
	linked := filepath.Join(dir, "raw"+strings.ToLower(filepath.Ext(s.in.Name)))
	if err := os.Symlink(source, linked); err != nil {
		return "", err
	}

	if _, err := s.run(Patience, "simple_dcraw", "-e", linked); err == nil {
		if carried, _ := filepath.Glob(linked + ".thumb.*"); len(carried) > 0 {
			if width, err := s.header(carried[0], "width"); err == nil && width >= RawMinimum {
				return carried[0], nil
			}
			os.Remove(carried[0])
		}
	}

	if _, err := s.run(Patience, "simple_dcraw", "-T", linked); err != nil {
		return "", fmt.Errorf("%s carries no image simple_dcraw could read: %w", s.in.Name, err)
	}
	if developed, _ := filepath.Glob(linked + ".tiff"); len(developed) > 0 {
		return developed[0], nil
	}
	return "", errors.New(s.in.Name + " carries no image simple_dcraw could read")
}
