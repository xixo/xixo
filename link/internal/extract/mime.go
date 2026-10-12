package extract

import (
	"path/filepath"
	"slices"
	"strings"
)

const (
	PDF   = "application/pdf"
	Page  = "xixo/page"
	JPEG  = "image/jpeg"
	Plain = "text/plain"
)

var raw = []string{
	"3fr", "ari", "arw", "cap", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "k25", "kdc", "mdc", "mos",
	"mrw", "nef", "nrw", "orf", "ori", "pef", "pxn", "raf", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
}

var Animatable = []string{"image/gif", "image/webp", "image/apng"}

func Extension(name string) string {
	return strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
}

func Raw(name string) bool {
	return slices.Contains(raw, Extension(name))
}

func Image(mime string) bool { return strings.HasPrefix(mime, "image/") }
func Audio(mime string) bool { return strings.HasPrefix(mime, "audio/") }
func Video(mime string) bool { return strings.HasPrefix(mime, "video/") }

func Text(mime string) bool {
	return strings.HasPrefix(mime, "text/") && mime != "text/calendar" && mime != "text/vcard"
}

func Thumbnailable(mime string) bool {
	return Image(mime) || Video(mime) || Audio(mime) || mime == PDF || mime == Page
}

func Describable(mime string) bool {
	return !Text(mime) && !strings.HasSuffix(mime, "/json") && !strings.HasSuffix(mime, "+json") &&
		!strings.HasSuffix(mime, "/xml") && !strings.HasSuffix(mime, "+xml")
}
