# documents

The `pdf`, `doc`, and `image` extractors. Each registers with `extract.Register`
when the package is imported.

## pdf

Handles `application/pdf`. Needs `pdfinfo`, `pdftotext`, `pdftoppm`, and
`tesseract`.

| Step | Result |
|---|---|
| `info` | `{pages (integer), title, author, creationdate, page_size}`, holding only the fields pdfinfo printed |
| `text` | The text layer. When it holds fewer than 40 visible characters a page, the first 30 pages are rendered at 200 dpi in gray and read by tesseract, and that text is used when it holds anything. Digest: `text layer, then ocr past 40 characters a page`. |

A pdf with more than 30 pages that needs OCR drops `pages`. A broken pdf still
answers: `info` carries an error and `text` holds whatever pdftotext read.

## doc

Handles `application/msword`, docx, and odt. Needs `soffice`, `pdfinfo`, and
`pdftotext`.

| Step | Result |
|---|---|
| `info` | The pdfinfo fields of the pdf LibreOffice makes, with its own profile in the work dir |
| `text` | For docx and odt, the document's own XML: headings become `#` lines (Title is level 1, `Heading N` or the outline level otherwise), paragraphs are separated by a blank line, and each table row is its cells joined by ` \| `. A document with no readable XML, and every legacy `.doc`, uses the pdf's text. Digest: `headings and tables from the document itself, else the pdf's text`. |

A document XML entry larger than 50 MiB is not read.

## image

Handles every `image/*` type. Needs `vipsheader`, `vips`, `exiftool`,
`tesseract`, and `simple_dcraw`.

| Step | Result |
|---|---|
| `dimensions` | `{width, height}` in pixels |
| `deviation` | The standard deviation of the pixels on a 0 to 255 scale, whatever the bit depth. Below 1.0 the image is flat. |
| `frames` | For gif, webp, and apng: the number of frames, 1 for a still |
| `location` | `{latitude, longitude}` from the GPS tags, rounded to six places, or null. Digest: `exiftool`. |
| `ocr` | What tesseract reads. A format tesseract cannot open is flattened to png by vips first. |

A raw photograph (nef, cr2, dng, and the other dcraw formats, chosen by the
filename's extension) is read from its embedded preview when that is at least
1024 pixels wide, and developed to tiff otherwise. Both are written in the work
dir, never beside the original. `location` always reads the original.

An animation with more than one frame sends evenly spaced frames as `frame`
files: JPEG, 768 pixels wide, named `frame-N.jpg` for frame N counted from 0, at
most `Settings.Frames` of them.

## Tests

`go test` runs everything that needs no outside program anywhere. The rest skips
when a program is missing, so run the package in a Linux image with
poppler-utils, tesseract-ocr, libreoffice-writer, libvips-tools,
libimage-exiftool-perl, and libraw-bin. `XIXO_CORPUS` naming xixo's
`test/fixtures/corpus` also runs the raw photograph.

`testdata/golden` holds what the Ruby analyzers read from the corpus pdf, doc,
and image files on 11 October 2026, as a reference.
