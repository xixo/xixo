package rich

import "testing"

func TestMacSignalRoundsLikeFfmpegPrints(t *testing.T) {
	loud, spread, peak, centroid, flatness := -16.226866, 5.430484, -2.193460, 1175.630794, 0.178090599
	found := MacSignal(macSignal{
		Loudness: &loud, Range: &spread, Peak: &peak, Centroid: &centroid, Flatness: &flatness,
		Silent: 4.129999, Silences: [][]float64{{5.62, 8}, {14.25, 16}, {1}},
	}, 16, 3600)

	if *found.Loudness != -16.2 || *found.Range != 5.4 || *found.Peak != -2.2 || *found.Centroid != 1176 || *found.Flatness != 0.1781 {
		t.Fatalf("rounded %+v", found)
	}

	if found.Silent != 4.13 || len(found.Silences) != 2 || found.SilentThroughout {
		t.Fatalf("silences %+v", found)
	}

	if quiet := MacSignal(macSignal{Silent: 15.5}, 16, 3600); !quiet.SilentThroughout || quiet.Loudness != nil {
		t.Fatalf("a silent recording read %+v", quiet)
	}
}
