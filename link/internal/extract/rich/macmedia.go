package rich

import (
	"context"
	"encoding/json"
	"math"
	"strconv"
	"strings"

	"github.com/xixo/xixo/link/internal/extract"
)

func init() {
	if extract.OnMac {
		extract.Register(MacMedia{})
	}
}

type MacMedia struct{}

func (MacMedia) Name() string { return "media" }

func (MacMedia) Handles(mime, name string) bool { return Media{}.Handles(mime, name) }

func (MacMedia) Needs() []string { return []string{extract.MacProgram()} }

type macProbe struct {
	Format   string            `json:"format"`
	Duration float64           `json:"duration"`
	BitRate  int64             `json:"bit_rate"`
	Streams  []Stream          `json:"streams"`
	Tags     map[string]string `json:"tags"`
}

type macSignal struct {
	Loudness *float64    `json:"loudness"`
	Range    *float64    `json:"range"`
	Peak     *float64    `json:"peak"`
	Silent   float64     `json:"silent"`
	Silences [][]float64 `json:"silences"`
	Centroid *float64    `json:"centroid"`
	Flatness *float64    `json:"flatness"`
	Heard    float64     `json:"heard"`
}

func (MacMedia) Extract(ctx context.Context, in extract.Input) (*extract.Output, error) {
	out := &extract.Output{Extractor: "media"}

	probe, err := macProbed(ctx, in)
	if err != nil {
		return nil, err
	}

	out.Set("probe", probe)

	span := in.Set.Settled().Transcribe

	if probe.audio() && !in.Skipped("signal") {
		var said macSignal
		if err := extract.AskMac(ctx, in.Run, extract.DefaultTime, &said, "signal", in.Path, "--seconds", strconv.Itoa(span)); err != nil {
			out.Fail("signal", err)
		} else {
			out.Set("signal", MacSignal(said, probe.Duration, span))
		}
	}

	if probe.audio() && !in.Skipped("transcript") {
		if err := macHeard(ctx, in, out, probe, span); err != nil {
			out.Fail("audio", err)
		}
	}

	if probe.video() && probe.Duration > 0 && !in.Skipped("scenes") {
		if err := macFrames(ctx, in, out, probe); err != nil {
			out.Fail("frames", err)
		}
	}

	return out, nil
}

func macHeard(ctx context.Context, in extract.Input, out *extract.Output, probe *Probe, span int) error {
	parts := Parts(probe.Duration, span)

	for index, part := range parts {
		file := part.file(in.Work, index)
		options := []string{"--out", file.Path, "--seconds", strconv.Itoa(part.Seconds)}

		if from := int(part.From); from > 0 {
			options = append(options, "--from", strconv.Itoa(from))
		}

		var said map[string]any
		if err := extract.AskMac(ctx, in.Run, extract.DefaultTime, &said, "audio", in.Path, options...); err != nil {
			return err
		}

		out.Attach(file)
	}

	partly(out, parts, probe.Duration, span)

	return nil
}

func macProbed(ctx context.Context, in extract.Input) (*Probe, error) {
	var said macProbe
	if err := extract.AskMac(ctx, in.Run, probeTime, &said, "media", in.Path); err != nil {
		return nil, err
	}

	probe := &Probe{Format: said.Format, BitRate: said.BitRate, Streams: []Stream{}, Tags: map[string]string{}}

	if finite(said.Duration) && said.Duration > 0 {
		probe.Duration = math.Round(said.Duration*100) / 100
	}

	for _, stream := range said.Streams[:min(mostStreams, len(said.Streams))] {
		probe.Streams = append(probe.Streams, stream)
	}

	for _, tag := range mediaTags {
		if value := extract.Truncate(extract.Squish(valid(said.Tags[tag])), 200); value != "" {
			probe.Tags[tag] = value
		}
	}

	return probe, nil
}

func MacSignal(said macSignal, duration float64, span int) *Signal {
	heard := float64(span)
	if duration > 0 {
		heard = math.Min(duration, heard)
	}

	found := &Signal{
		Loudness: tenths(said.Loudness),
		Range:    tenths(said.Range),
		Peak:     tenths(said.Peak),
		Silences: [][2]float64{},
		Silent:   round(said.Silent, 2),
	}

	for _, pair := range said.Silences {
		if len(pair) == 2 && len(found.Silences) < mostSilences {
			found.Silences = append(found.Silences, [2]float64{round(pair[0], 2), round(pair[1], 2)})
		}
	}

	if said.Centroid != nil && finite(*said.Centroid) {
		rounded := math.Round(*said.Centroid)
		found.Centroid = &rounded
	}

	if said.Flatness != nil && finite(*said.Flatness) {
		rounded := round(*said.Flatness, 4)
		found.Flatness = &rounded
	}

	found.SilentThroughout = found.Loudness == nil || *found.Loudness <= silentFloor ||
		(heard > 0 && found.Silent >= heard*0.95)

	return found
}

func tenths(value *float64) *float64 {
	if value == nil || !finite(*value) {
		return nil
	}

	rounded := round(*value, 1)

	return &rounded
}

func macFrames(ctx context.Context, in extract.Input, out *extract.Output, probe *Probe) error {
	count := max(1, min(mostFrames, int(math.Floor(probe.Duration/sceneSeconds))))
	moments := make([]float64, count)
	listed := make([]string, count)

	for index := range count {
		moments[index] = round(probe.Duration*(float64(index)+0.5)/float64(count), 2)
		listed[index] = strconv.FormatFloat(moments[index], 'f', -1, 64)
	}

	var made struct {
		Frames []struct {
			Index int         `json:"index"`
			At    json.Number `json:"at"`
			Path  string      `json:"path"`
		} `json:"frames"`
	}

	if err := extract.AskMac(ctx, in.Run, probeTime, &made, "frames", in.Path, "--at", strings.Join(listed, ","),
		"--width", strconv.Itoa(frameWidth), "--out", in.Work); err != nil {
		return err
	}

	for _, frame := range made.Frames {
		if frame.Index < 0 || frame.Index >= count {
			continue
		}

		moment := moments[frame.Index]
		out.Attach(extract.File{Role: "frame", Name: stamped(moment), MIME: "image/jpeg", Path: frame.Path, At: &moment})
	}

	return nil
}
