# documents

The `pdf`, `doc`, and `image` extractors. Each registers with `extract` when the
package is imported.

## pdf

Reads `application/pdf` with `pdfinfo`, `pdftotext`, `pdftoppm`, and
`tesseract`.

| Step | Result |
| --- | --- |
| `info` | `pages`, `title`, `author`, `creationdate`, and `page_size`, as far as pdfinfo printed them. |
| `text` | The text layer. A PDF with fewer than 40 visible characters a page has its first 30 pages rendered at 200 dpi and read by tesseract, and that text is used when it holds anything. |

A broken PDF still answers: `info` holds an error and `text` holds whatever
pdftotext read.

## doc

Reads `.doc`, `.docx`, and `.odt` with `soffice`, `pdfinfo`, and `pdftotext`.

| Step | Result |
| --- | --- |
| `info` | The pdfinfo fields of the PDF that LibreOffice makes. |
| `text` | For `.docx` and `.odt`, the document's own XML: headings become `#` lines, paragraphs are separated by a blank line, and each table row is its cells joined by ` \| `. A legacy `.doc`, or a document with no readable XML, uses the PDF's text. |

## image

Reads every `image/*` type with `vipsheader`, `vips`, `exiftool`, `tesseract`,
and `simple_dcraw`.

| Step | Result |
| --- | --- |
| `dimensions` | `{width, height}` in pixels. |
| `deviation` | The standard deviation of the pixels on a 0 to 255 scale. Below 1.0 the image is flat. |
| `frames` | For GIF, WebP, and APNG, the number of frames. |
| `location` | `{latitude, longitude}` from the GPS tags, or null. |
| `ocr` | What tesseract reads. |

A camera raw file is read from its embedded preview when that is at least 1,024
pixels wide, and developed to TIFF otherwise, in the work folder.

An animation sends up to `settings.frames` evenly spaced frames as `frame`
files, JPEGs 768 pixels wide.

## On macOS

Three more extractors register under the same names and go first when their
programs are on the Mac:

- `pdf` with the mac reader reads each page's text with PDFKit, adds an
  `outline` step from the bookmarks, and reads sparse pages with Vision.
- `image` with the mac reader reads the same steps with ImageIO, which opens
  camera raw files directly, and reads text with Vision.
- `doc` with `textutil` also reads `.rtf` and `.webarchive`. `info` holds the
  title and author, with no page count.

## Tests

`go test` runs every test that needs no outside program. The rest skip when a
program is missing, so run the package in a Linux image with poppler-utils,
tesseract-ocr, libreoffice-writer, libvips-tools, libimage-exiftool-perl, and
libraw-bin. Set `XIXO_CORPUS` to xixo's `test/fixtures/corpus` to also read the
raw photograph.

The tests compare what they read with the files in `testdata/golden`.
