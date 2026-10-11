# Extraction

The agent turns a file's bytes into steps. Rails keeps everything that needs
a model, the catalog, or the database: summaries, captions, transcription,
scene captions, places, passages, embeddings, and the rows for child feeds
and derived files.

## The request

xixo asks with the `extract` verb.

```json
{"request": "<id>", "verb": "extract", "args": {
  "source": {"upload": "<upload id>"},
  "mime": "text/calendar",
  "filename": "dentist.ics",
  "size": 1234,
  "skip": ["metadata"],
  "settings": {"thumbnail": 320, "preview": 1500, "frames": 4, "transcribe": 3600}
}}
```

`source` is either `{"folder", "path"}`, a file one of the agent's folders
shares, or `{"upload": id}`, bytes xixo sent first with `put` requests under
that id. `skip` names steps xixo already holds. `settings` carries the
server's thumbnail width, preview width, animation frames, and the seconds of
audio to transcribe; a missing value takes the server's default.

xixo asks for thumbnails alone with the `derive` verb, which takes the same
args and answers with only the `derived` step and its files. A page capture
(`xixo/page`) uses it, since its text never leaves Rails.

## The answer

The reply's result is:

```json
{
  "extractor": "calendar",
  "steps": {"events": {"result": []}, "text": {"result": "..."}},
  "dropped": {"text": "only the first 200,000 of 210,000 characters were read"},
  "files": [{"role": "thumbnail", "name": "thumbnail.jpg", "mime": "image/jpeg",
             "size": 4096, "request_file": "<file id>"}]
}
```

Each step holds a `result`, or an `error` when that step failed and the rest
went on. A whole extraction fails only when the file cannot be opened or no
extractor reads it. `dropped` says what was cut, one sentence for each thing.
Each file's bytes arrive as `chunk` frames under its own `request_file` id,
tagged `of` the extract request. `at` is a frame's time in seconds.

The extractor is chosen in this order, first match wins: pdf, image, media,
doc, epub, xlsx, calendar, pkpass, email, contact, data, text, fallback.
`extractors` in the agent's hello lists the ones whose programs are present.

## Steps every extractor gets

| Step | When | Result |
|---|---|---|
| `metadata` | not text, JSON, or XML | an object of exiftool tags, group prefixes dropped, plumbing tags left out, at most 200 tags, values cut at 500 characters, lists joined with `, ` |
| `derived` | images, video, audio, PDFs, page captures | `{"thumbnail": "thumbnail.jpg", "preview": "preview.jpg"}`, with both files attached in the roles `thumbnail` and `preview` |

A thumbnail is `settings.thumbnail` pixels wide. A preview fits within
`settings.preview` pixels on its longest edge, except a page capture's, which
keeps its full length at that width. Video takes the frame one second in,
audio draws its waveform, a PDF renders its first page, and a camera raw uses
its embedded preview when that is at least 1,024 pixels wide.

## text

Any `text/*` type except calendars and vCards.

| Step | Result |
|---|---|
| `text` | the file decoded by its byte order mark, as UTF-8, or as Windows-1252, trimmed, at most 200,000 characters |

## data

`application/json`, `application/xml`, `text/csv`, `text/tab-separated-values`.

| Step | Result |
|---|---|
| `shape` | `{"format": "json", "keys": [...]}` with the first 50 top-level keys in order, `{"format": "csv", "columns": [...], "rows": n}`, `{"format": "invalid", "error": "..."}`, or `{"format": "unknown"}` for XML and anything else |
| `tables` | `.csv` and `.tsv` only: `[{"name", "columns", "rows"}]`, the header found in the first ten rows as the widest one, total rows left out, at most 5,000 rows; empty when the file does not parse |
| `text` | as `text` |

## calendar

`text/calendar`.

| Step | Result |
|---|---|
| `events` | up to 200 objects with any of `summary`, `description`, `location`, `dtstart`, `dtend`, `organizer`, `status`, `uid`, each unescaped and cut at 1,000 characters |
| `outline` | `[{"name", "from"}]`, one section per event named by its summary and date, `from` a character offset into `text` |
| `text` | one line per event: summary, the start written out as a date, location, and description, joined with ` · ` |

A start such as `20261012T093000Z` reads as `Monday, October 12, 2026, 09:30 UTC`.

## contact

`text/vcard`.

| Step | Result |
|---|---|
| `contacts` | up to 500 objects; `fn`, `title`, `org`, `note`, `bday`, `nickname`, `role` are strings, `email`, `tel`, `url`, `impp`, and `adr` are lists, and `name` is the structured name joined with spaces |
| `outline` | one section per contact, named by its full name, its name, or its first email |
| `text` | one line per contact: name, org, title, emails, phones, addresses, and note, joined with ` · ` |

## pkpass

`application/vnd.apple.pkpass`.

| Step | Result |
|---|---|
| `pass` | `{"style", "organization", "description", "logo_text", "serial_number", "relevant_date", "expiration_date", "fields": [{"label", "value"}]}` from `pass.json`, or an error when the bundle is not a zip, has no `pass.json`, or it is not JSON |
| `text` | the pass's values, then one `label: value` line per field |

## fallback

Everything else.

| Step | Result |
|---|---|
| `size` | `{"bytes": n}` |
| `format` | `{"declared": mime, "observed": "zip" \| "gzip" \| "pdf" \| "executable" \| "audio" \| "media" \| "image" \| "tar" \| "text" \| "binary", "printable": bool}` from the first 8 KiB |
| `text` | printable files only; HTML, XHTML, SVG, XML, or anything starting with `<` has its markup stripped, headings kept as `#` lines |
| `listing` | zip, tar, and gzipped tar: the first 200 entry names, leaving out pax headers and `._` AppleDouble files |

## Programs

Every program runs under `Limited`: a deadline, a 4 GiB data limit on Linux,
and its whole process group killed past the deadline. `exiftool`, `vipsthumbnail`,
`vipsheader`, `ffmpeg`, `ffprobe`, `pdftoppm`, and `simple_dcraw` are used
here; an extractor names the ones it needs, and one whose programs are missing
is left out of `extractors`.
