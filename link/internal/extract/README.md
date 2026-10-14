# Extraction

xixo link turns a file's bytes into steps. Rails keeps everything that needs a
model, the catalog, or the database: summaries, captions, transcription, places,
passages, embeddings, and the rows for child feeds and derived files.

## The request

xixo asks with the `extract` verb:

```json
{"request": "<id>", "verb": "extract", "args": {
  "source": {"upload": "<upload id>"},
  "mime": "text/calendar",
  "filename": "dentist.ics",
  "size": 1234,
  "skip": ["metadata"],
  "settings": {"thumbnail": 320, "preview": 1500, "frames": 4, "share": 100, "transcribe": 3600}
}}
```

- `source` is a shared file, `{"folder", "path"}`, or an upload, `{"upload": id}`,
  which xixo link fetches from `<xixo>/link/uploads/<id>` and which must be
  exactly `size` bytes. An upload is at most 4 GB.
- `skip` names steps xixo already holds.
- `settings` holds the tenant's thumbnail width, preview width, the most frames
  and the percentage of frames read from an animation, and the seconds of audio
  to transcribe, at most four hours. A missing value takes the default shown
  above.

The `derive` verb takes the same arguments and answers with only the `derived`
step and its files. A page capture (`xixo/page`) uses it, since its text never
leaves Rails.

## The answer

```json
{
  "extractor": "calendar",
  "steps": {"events": {"result": []}, "text": {"result": "..."}},
  "dropped": {"text": "only the first 200,000 of 210,000 characters were read"},
  "files": [{"role": "thumbnail", "name": "thumbnail.jpg", "mime": "image/jpeg",
             "size": 4096, "request_file": "<file id>"}]
}
```

- Each step holds a `result`, or an `error` when that step failed and the rest
  went on. A whole extraction fails only when the file cannot be opened or no
  extractor reads it.
- `dropped` says what was cut, one sentence for each thing.
- Each file's bytes arrive first as `chunk` messages under its own
  `request_file` id, with `of` naming the extract request. A video frame also
  holds `at`, its time in seconds.

## Extractors

The first extractor in this list that handles the file's type reads it:

| Extractor | Types | Steps | Package |
| --- | --- | --- | --- |
| `pdf` | PDF | `info`, `text`, and on macOS `outline` | [documents](documents/README.md) |
| `image` | `image/*` | `dimensions`, `deviation`, `frames`, `location`, `ocr` | [documents](documents/README.md) |
| `media` | `audio/*` and `video/*` | `probe`, `signal` | [rich](rich/README.md) |
| `doc` | `.doc`, `.docx`, `.odt` | `info`, `text` | [documents](documents/README.md) |
| `epub` | EPUB | `book`, `text` | [rich](rich/README.md) |
| `xlsx` | `.xlsx`, `.xls`, `.ods` | `sheets`, `tables`, `outline`, `text` | [rich](rich/README.md) |
| `calendar` | `text/calendar` | `events`, `outline`, `text` | `plain` |
| `pkpass` | Apple Wallet passes | `pass`, `text` | `plain` |
| `email` | `message/rfc822` | `headers`, `thread`, `attachments`, `text`, `outline` | [rich](rich/README.md) |
| `contact` | `text/vcard` | `contacts`, `outline`, `text` | `plain` |
| `data` | JSON, XML, CSV, and TSV | `shape`, `text`, and for CSV and TSV `tables` | `plain` |
| `text` | other `text/*` types | `text` | `plain` |
| `fallback` | everything else | `size`, `format`, `text` for printable files, `listing` for archives | `plain` |

`extractors` in xixo link's `hello` lists the extractors whose programs are on
the machine. On macOS, `pdf`, `image`, `doc`, and `media` each have a second
extractor built on the mac reader or `textutil`, with the same steps. See
[what a Mac reads](../../README.md#what-a-mac-reads).

Text is cut at 200,000 characters. An outline's `from` is a character offset
into `text`.

## Steps every extractor gets

| Step | For | Result |
| --- | --- | --- |
| `metadata` | every type except text, JSON, and XML | The exiftool tags, at most 200, each value cut at 500 characters. On a Mac without exiftool, the tags the mac reader or `textutil -info` reads, under exiftool's names. |
| `derived` | images, video, audio, PDFs, and page captures | `{"thumbnail", "preview"}`, with both files attached in those roles. |

A thumbnail is `settings.thumbnail` pixels wide. A preview fits within
`settings.preview` pixels on its longest edge, except a page capture's, which
keeps its full length. Video takes the frame one second in, audio draws its
waveform, and a PDF renders its first page. Both files are sRGB and keep none
of the original's metadata, so a photo's location stays in the original only.

## Where the file is read

A shared file is read where it lies, with no copy, so a film of any size is
read on the machine that shares it. The work folder holds a link named
`source` with the file's extension, and every program and every Go extractor
reads the file through it.

- On Linux the link points at the file xixo link opened, through
  `/proc/self/fd`. Each program gets that open file, so a symbolic link or a
  file swapped in at the path is never read.
- On macOS the link points at the file's own path, and the sandbox lets the
  programs read that one file and nothing else in the shared folder.
- xixo link names the file's SHA-256 from that open file, and asks its
  remembered SHA-256 values first, so a film it hashed for a sync is not read
  again.
- When the extraction ends, xixo link checks the file once more. When its
  size, modification time, or change time moved, or another file took its
  path, xixo link sends nothing and refuses the request with an error that
  says the file changed. xixo asks again later.

The `doc` and `xlsx` extractors still copy the file into the work folder,
since LibreOffice may write lock and backup files beside the document it
opens. A copy holds at most 4 GB. An upload is always a file in the work
folder.

## Programs

Every program runs with a deadline, and its whole process group is killed past
it. `/bin/sh` sets a data limit with `ulimit -d` and a file size limit with
`ulimit -f` just before the program starts. Both are 4 GiB, except that
exiftool gets 6 GiB of data, since its zip reader sizes a buffer from a zip64
header's 4 GiB placeholder. macOS refuses `ulimit -d`, so there the file size
limit holds alone.

On macOS each program also runs under `sandbox-exec`, which lets it write only
inside the extraction's work folder, read only the one shared file it extracts,
and reach no network. See [the sandbox](../../README.md#the-sandbox).

An extractor names the programs it needs. One whose programs are missing is
left out of `extractors`.
