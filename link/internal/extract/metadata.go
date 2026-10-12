package extract

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strings"
	"time"
)

const (
	metadataTime = 30 * time.Second
	mostTags     = 200
	mostValue    = 500
	mostListed   = 24
)

var quiet = []string{"ExifTool", "File", "System", "ICC_Profile", "MakerNotes", "JFIF", "APP14", "Photoshop", "PrintIM", "ZIP", "JSON"}

var plumbing = strings.Fields(`
	SourceFile ExifByteOrder ExifVersion FlashpixVersion ComponentsConfiguration
	XResolution YResolution ResolutionUnit YCbCrPositioning YCbCrSubSampling
	ThumbnailOffset ThumbnailLength ThumbnailImage PreviewImage PreviewImageStart
	PreviewImageLength JpgFromRaw JpgFromRawStart JpgFromRawLength OtherImage
	OtherImageStart OtherImageLength StripOffsets StripByteCounts RowsPerStrip
	PlanarConfiguration BitsPerSample SamplesPerPixel Compression EncodingProcess
	InteropIndex InteropVersion PDFVersion Linearized XMPToolkit DocumentID
	InstanceID OriginalDocumentID DerivedFromDocumentID DerivedFromInstanceID
	HistoryAction HistoryInstanceID HistoryWhen HistorySoftwareAgent HistoryChanged
	CFAPattern CFAPattern2 CFARepeatPatternDim ReferenceBlackWhite TIFF-EPStandardID
	SubfileType PhotometricInterpretation GPSVersionID SubSecTime SubSecTimeOriginal
	SubSecTimeDigitized SubSecCreateDate SubSecModifyDate SubSecDateTimeOriginal
	FocalLength35efl ScaleFactor35efl CircleOfConfusion HyperfocalDistance FOV
	DigitalZoomRatio RedBalance BlueBalance BlackLevel WhiteLevel
	MatrixStructure GraphicsMode OpColor HandlerType HandlerVendorID HandlerDescription
	MediaDataOffset MediaDataSize MediaHeaderVersion MovieHeaderVersion TrackHeaderVersion
	NextTrackID TrackID TrackLayer TrackVolume PreferredRate PreferredVolume PreviewTime
	PreviewDuration PosterTime SelectionTime SelectionDuration CurrentTime TimeScale
	MediaTimeScale BufferSize MinorVersion SourceImageWidth SourceImageHeight BitDepth
	AverageBitrate Emphasis CopyrightFlag OriginalMedia IntensityStereo MSStereo
	RevisionNumber TotalEditTime Template AppVersion Xmlns`)

var unset = regexp.MustCompile(`\A(0000:00:00 00:00:00|0+ s)\z`)

type Tag struct {
	Name  string `json:"name"`
	Value any    `json:"value"`
}

type Metadata []Tag

func (m Metadata) MarshalJSON() ([]byte, error) {
	var out strings.Builder

	out.WriteByte('{')

	for at, tag := range m {
		if at > 0 {
			out.WriteByte(',')
		}

		name, _ := json.Marshal(tag.Name)
		value, err := json.Marshal(tag.Value)
		if err != nil {
			return nil, err
		}

		out.Write(name)
		out.WriteByte(':')
		out.Write(value)
	}

	out.WriteByte('}')

	return []byte(out.String()), nil
}

func ReadMetadata(ctx context.Context, run Runner, path string) (Metadata, error) {
	out, err := run.Run(ctx, metadataTime, "exiftool", "-json", "-G0", "-fast", "-api", "LargeFileSupport=1", path)
	if err != nil && len(out) == 0 {
		return nil, err
	}

	decoder := json.NewDecoder(strings.NewReader(string(out)))
	decoder.UseNumber()

	if token, err := decoder.Token(); err != nil || token != json.Delim('[') {
		return nil, errors.New("exiftool said something unreadable")
	}

	if !decoder.More() {
		return Metadata{}, nil
	}

	return tidy(decoder)
}

func tidy(decoder *json.Decoder) (Metadata, error) {
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil, errors.New("exiftool said something unreadable")
	}

	held := Metadata{}
	seen := map[string]bool{}

	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("exiftool said something unreadable: %w", err)
		}

		var value any
		if err := decoder.Decode(&value); err != nil {
			return nil, fmt.Errorf("exiftool said something unreadable: %w", err)
		}

		named := key.(string)
		group, tag := "", named

		if before, after, found := strings.Cut(named, ":"); found {
			group, tag = before, after
		}

		if slices.Contains(quiet, group) || slices.Contains(plumbing, tag) || seen[tag] {
			continue
		}

		if shown := showing(value); shown != nil {
			held = append(held, Tag{Name: tag, Value: shown})
			seen[tag] = true
		}

		if len(held) >= mostTags {
			break
		}
	}

	return held, nil
}

func showing(value any) any {
	switch held := value.(type) {
	case []any:
		listed := []string{}

		for _, each := range held {
			if shown := showing(each); shown != nil {
				listed = append(listed, fmt.Sprint(shown))
			}

			if len(listed) >= mostListed {
				break
			}
		}

		if len(listed) == 0 {
			return nil
		}

		return strings.Join(listed, ", ")
	case map[string]any:
		return nil
	case json.Number:
		if whole, err := held.Int64(); err == nil {
			return whole
		}

		if real, err := held.Float64(); err == nil && !math.IsInf(real, 0) && !math.IsNaN(real) {
			return real
		}

		return held.String()
	case bool:
		return held
	case nil:
		return nil
	default:
		text := strings.TrimSpace(strings.ToValidUTF8(fmt.Sprint(held), "�"))
		if text == "" || strings.HasPrefix(text, "(Binary data") || unset.MatchString(text) {
			return nil
		}

		return Truncate(text, mostValue)
	}
}
