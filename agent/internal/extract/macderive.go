package extract

import "strconv"

func (d *deriving) onMac() (string, bool, error) {
	if !OnMac || MacReader() == "" {
		return "", false, nil
	}

	switch {
	case d.in.MIME == Page:
		if Present("vipsthumbnail") {
			return "", false, nil
		}

		if d.hires() {
			return d.fromMac("image", false, "")
		}

		return d.fromMac("image", false, "top")
	case d.in.MIME == PDF:
		return d.fromMac("pdf", d.hires(), "")
	case Video(d.in.MIME):
		if Present("ffmpeg") {
			return "", false, nil
		}

		return d.fromMac("video", d.hires(), "")
	case Audio(d.in.MIME):
		if Present("ffmpeg") {
			return "", false, nil
		}

		return d.fromMac("audio", false, "")
	default:
		return d.fromMac("image", d.hires(), "")
	}
}

func (d *deriving) fromMac(kind string, fit bool, crop string) (string, bool, error) {
	options := []string{"--kind", kind, "--out", d.out(), "--width", strconv.Itoa(d.width)}

	if fit {
		options = append(options, "--fit", "true")
	}

	if crop != "" {
		options = append(options, "--crop", crop)
	}

	var said struct {
		Path string `json:"path"`
	}

	if err := AskMac(d.ctx, d.in.Run, deriveTime, &said, "thumbnail", d.in.Path, options...); err != nil {
		return "", true, err
	}

	made, err := d.made(d.out())

	return made, true, err
}
