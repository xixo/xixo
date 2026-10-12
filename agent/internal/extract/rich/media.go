package rich

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/xixo/xixo/agent/internal/extract"
)

const (
	mostStreams     = 8
	silence         = "-50dB"
	shortestSilence = 0.5
	mostSilences    = 20
	silentFloor     = -70.0
	mostFrames      = 8
	sceneSeconds    = 8
	frameWidth      = 768
	probeTime       = 2 * time.Minute
)

var mediaTags = []string{"title", "artist", "album_artist", "album", "date", "genre", "composer", "comment"}

var stills = []string{"mjpeg", "png", "gif", "bmp"}

var (
	integrated   = regexp.MustCompile(`I:\s+(-?[\d.]+) LUFS`)
	loudRange    = regexp.MustCompile(`LRA:\s+([\d.]+) LU`)
	peaked       = regexp.MustCompile(`Peak:\s+(-?[\d.]+) dBFS`)
	silenceStart = regexp.MustCompile(`silence_start: (-?[\d.]+)`)
	silenceEnd   = regexp.MustCompile(`silence_end: ([\d.]+)`)
)

type Media struct{}

func (Media) Name() string { return "media" }

func (Media) Handles(mime, name string) bool {
	return strings.HasPrefix(mime, "audio/") || strings.HasPrefix(mime, "video/")
}

func (Media) Needs() []string { return []string{"ffmpeg", "ffprobe", "sh"} }

type Stream struct {
	Type       string `json:"type,omitempty"`
	Codec      string `json:"codec,omitempty"`
	Width      int    `json:"width,omitempty"`
	Height     int    `json:"height,omitempty"`
	Channels   int    `json:"channels,omitempty"`
	SampleRate int    `json:"sample_rate,omitempty"`
	Language   string `json:"language,omitempty"`
}

type Probe struct {
	Format   string            `json:"format,omitempty"`
	Duration float64           `json:"duration,omitempty"`
	BitRate  int64             `json:"bit_rate,omitempty"`
	Streams  []Stream          `json:"streams"`
	Tags     map[string]string `json:"-"`
}

func (p Probe) MarshalJSON() ([]byte, error) {
	type plain Probe

	body, err := json.Marshal(plain(p))
	if err != nil || len(p.Tags) == 0 {
		return body, err
	}

	held := map[string]any{}
	if err := json.Unmarshal(body, &held); err != nil {
		return nil, err
	}

	for tag, value := range p.Tags {
		held[tag] = value
	}

	return json.Marshal(held)
}

func (p *Probe) UnmarshalJSON(body []byte) error {
	type plain Probe

	if err := json.Unmarshal(body, (*plain)(p)); err != nil {
		return err
	}

	held := map[string]any{}
	if err := json.Unmarshal(body, &held); err != nil {
		return err
	}

	p.Tags = map[string]string{}

	for _, tag := range mediaTags {
		if value, ok := held[tag].(string); ok {
			p.Tags[tag] = value
		}
	}

	return nil
}

type Signal struct {
	Loudness         *float64     `json:"loudness,omitempty"`
	Range            *float64     `json:"range,omitempty"`
	Peak             *float64     `json:"peak,omitempty"`
	Silent           float64      `json:"silent"`
	Silences         [][2]float64 `json:"silences"`
	Centroid         *float64     `json:"centroid,omitempty"`
	Flatness         *float64     `json:"flatness,omitempty"`
	SilentThroughout bool         `json:"silent_throughout"`
}

func (Media) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{Extractor: "media"}

	probe, err := probed(ctx, in)
	if err != nil {
		return nil, err
	}

	out.Set("probe", probe)

	if probe.audio() && !in.Skipped("signal") {
		if found, err := signal(ctx, in, probe); err != nil {
			out.Fail("signal", err)
		} else {
			out.Set("signal", found)
		}
	}

	if probe.audio() && !in.Skipped("transcript") {
		if err := heard(ctx, in, out, probe); err != nil {
			out.Fail("audio", err)
		}
	}

	if probe.video() && probe.Duration > 0 && !in.Skipped("scenes") {
		if err := frames(ctx, in, out, probe); err != nil {
			out.Fail("frames", err)
		}
	}

	return out, nil
}

func probed(ctx context.Context, in extract.Input) (*Probe, error) {
	said, err := in.Run.Run(ctx, probeTime, "ffprobe", "-v", "error", "-print_format", "json",
		"-show_format", "-show_streams", in.Path)
	if err != nil {
		return nil, err
	}

	var parsed struct {
		Format struct {
			Name     string            `json:"format_name"`
			Duration string            `json:"duration"`
			BitRate  string            `json:"bit_rate"`
			Tags     map[string]string `json:"tags"`
		} `json:"format"`
		Streams []struct {
			Type       string            `json:"codec_type"`
			Codec      string            `json:"codec_name"`
			Width      int               `json:"width"`
			Height     int               `json:"height"`
			Channels   int               `json:"channels"`
			SampleRate string            `json:"sample_rate"`
			Tags       map[string]string `json:"tags"`
		} `json:"streams"`
	}

	if err := json.Unmarshal(said, &parsed); err != nil {
		return nil, fmt.Errorf("ffprobe did not describe %s", in.Name)
	}

	probe := &Probe{Format: parsed.Format.Name, Streams: []Stream{}, Tags: map[string]string{}}

	if duration, err := strconv.ParseFloat(parsed.Format.Duration, 64); err == nil && finite(duration) && duration > 0 {
		probe.Duration = math.Round(duration*100) / 100
	}

	if rate, err := strconv.ParseInt(parsed.Format.BitRate, 10, 64); err == nil {
		probe.BitRate = rate
	}

	for _, stream := range parsed.Streams[:min(mostStreams, len(parsed.Streams))] {
		rate, _ := strconv.Atoi(stream.SampleRate)
		probe.Streams = append(probe.Streams, Stream{
			Type: stream.Type, Codec: stream.Codec, Width: stream.Width, Height: stream.Height,
			Channels: stream.Channels, SampleRate: rate, Language: stream.Tags["language"],
		})
	}

	lowered := map[string]string{}
	for key, value := range parsed.Format.Tags {
		lowered[strings.ToLower(key)] = value
	}

	for _, tag := range mediaTags {
		if value := extract.Truncate(extract.Squish(valid(lowered[tag])), 200); value != "" {
			probe.Tags[tag] = value
		}
	}

	return probe, nil
}

func (p *Probe) audio() bool {
	return slices.ContainsFunc(p.Streams, func(s Stream) bool { return s.Type == "audio" })
}

func (p *Probe) video() bool {
	return slices.ContainsFunc(p.Streams, func(s Stream) bool {
		return s.Type == "video" && !slices.Contains(stills, s.Codec)
	})
}

func signal(ctx context.Context, in extract.Input, probe *Probe) (*Signal, error) {
	span := in.Set.Settled().Transcribe

	spectral := filepath.Join(in.Work, "spectral.txt")
	graph := strings.Join([]string{
		"ebur128=peak=true:framelog=quiet",
		fmt.Sprintf("silencedetect=noise=%s:d=%g", silence, shortestSilence),
		"aformat=channel_layouts=mono",
		"aspectralstats=measure=centroid+flatness",
		"ametadata=mode=print:file=" + escapedFilter(spectral),
	}, ",")

	said, err := in.Run.Run(ctx, extract.DefaultTime, "sh", "-c", `exec "$@" 2>&1`, "sh",
		"ffmpeg", "-hide_banner", "-nostats", "-i", in.Path, "-vn",
		"-t", strconv.Itoa(span), "-af", graph, "-f", "null", "-")
	if err != nil {
		return nil, fmt.Errorf("ffmpeg could not measure %s: %w", in.Name, err)
	}

	return measured(string(said), spectralLines(spectral), probe.Duration, span), nil
}

func escapedFilter(path string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `:`, `\:`, `'`, `\'`, `,`, `\,`, `;`, `\;`, `[`, `\[`, `]`, `\]`)

	return replacer.Replace(path)
}

func spectralLines(path string) []string {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()

	lines := []string{}
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}

	return lines
}

func measured(said string, frames []string, duration float64, span int) *Signal {
	heard := float64(span)
	if duration > 0 {
		heard = math.Min(duration, heard)
	}

	found := &Signal{
		Loudness: number(integrated, said),
		Range:    number(loudRange, said),
		Peak:     number(peaked, said),
		Silences: [][2]float64{},
	}

	starts := silenceStart.FindAllStringSubmatch(said, -1)
	ends := silenceEnd.FindAllStringSubmatch(said, -1)
	silent := 0.0

	for index, start := range starts {
		from, _ := strconv.ParseFloat(start[1], 64)
		to := heard

		if index < len(ends) {
			to, _ = strconv.ParseFloat(ends[index][1], 64)
		}

		pair := [2]float64{round(math.Max(from, 0), 2), round(to, 2)}
		silent += pair[1] - pair[0]

		if len(found.Silences) < mostSilences {
			found.Silences = append(found.Silences, pair)
		}
	}

	found.Silent = round(silent, 2)

	if centroid := middle(series(frames, "centroid")); centroid != nil {
		rounded := math.Round(*centroid)
		found.Centroid = &rounded
	}

	if flatness := middle(series(frames, "flatness")); flatness != nil {
		rounded := round(*flatness, 4)
		found.Flatness = &rounded
	}

	found.SilentThroughout = found.Loudness == nil || *found.Loudness <= silentFloor ||
		(heard > 0 && found.Silent >= heard*0.95)

	return found
}

func number(pattern *regexp.Regexp, said string) *float64 {
	match := pattern.FindStringSubmatch(said)
	if match == nil {
		return nil
	}

	value, err := strconv.ParseFloat(match[1], 64)
	if err != nil || !finite(value) {
		return nil
	}

	return &value
}

func series(lines []string, measure string) []float64 {
	pattern := regexp.MustCompile(`\.` + measure + `=(\S+)`)
	values := []float64{}

	for _, line := range lines {
		match := pattern.FindStringSubmatch(line)
		if match == nil {
			continue
		}

		if value, err := strconv.ParseFloat(match[1], 64); err == nil && finite(value) {
			values = append(values, value)
		}
	}

	return values
}

func middle(values []float64) *float64 {
	if len(values) == 0 {
		return nil
	}

	slices.Sort(values)

	return &values[len(values)/2]
}

func round(value float64, places int) float64 {
	scale := math.Pow(10, float64(places))

	return math.Round(value*scale) / scale
}

func finite(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}

func heard(ctx context.Context, in extract.Input, out *extract.Output, probe *Probe) error {
	wav := filepath.Join(in.Work, "heard.wav")
	span := in.Set.Settled().Transcribe

	if _, err := in.Run.Run(ctx, extract.DefaultTime, "ffmpeg", "-v", "error", "-y", "-i", in.Path, "-vn",
		"-t", strconv.Itoa(span), "-ac", "1", "-ar", "16000", "-f", "wav", wav); err != nil {
		return err
	}

	if probe.Duration > float64(span) {
		out.Drop("transcript", fmt.Sprintf("only the first %s of %s were heard", stamped(float64(span)), stamped(probe.Duration)))
	}

	out.Attach(extract.File{Role: "audio", Name: "heard.wav", MIME: "audio/wav", Path: wav})

	return nil
}

func frames(ctx context.Context, in extract.Input, out *extract.Output, probe *Probe) error {
	count := max(1, min(mostFrames, int(math.Floor(probe.Duration/sceneSeconds))))

	for index := range count {
		at := probe.Duration * (float64(index) + 0.5) / float64(count)
		frame := filepath.Join(in.Work, fmt.Sprintf("frame-%d.jpg", index))

		if _, err := in.Run.Run(ctx, probeTime, "ffmpeg", "-v", "error", "-y",
			"-ss", strconv.FormatFloat(round(at, 2), 'f', -1, 64), "-i", in.Path,
			"-frames:v", "1", "-vf", fmt.Sprintf("scale=%d:-2", frameWidth), frame); err != nil {
			return err
		}

		if _, err := os.Stat(frame); err != nil {
			continue
		}

		moment := round(at, 2)
		out.Attach(extract.File{Role: "frame", Name: stamped(at), MIME: "image/jpeg", Path: frame, At: &moment})
	}

	return nil
}

func stamped(seconds float64) string {
	held := int(seconds)

	return fmt.Sprintf("%02d:%02d:%02d", held/3600, held%3600/60, held%60)
}

func init() {
	extract.Register(Media{})
}
