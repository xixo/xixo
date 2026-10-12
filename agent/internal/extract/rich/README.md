# rich

The `rich` extractors read media, email, epub books, and spreadsheets. Each one
registers with `extract` under the name of the Ruby analyzer it replaces, and
returns steps, notes on what it left out, and files. Offsets in an outline
count characters, the way Ruby strings do.

## media

Handles every `audio/*` and `video/*` type, and needs `ffmpeg`, `ffprobe`, and
`sh`.

- `probe`: `format`, `duration` in seconds, `bit_rate`, up to eight `streams`
  (`type`, `codec`, `width`, `height`, `channels`, `sample_rate`, `language`),
  and the tags `title`, `artist`, `album_artist`, `album`, `date`, `genre`,
  `composer`, and `comment` at the top level.
- `signal`, for audio: `loudness` in LUFS, `range` in LU, `peak` in dBFS,
  `silent` seconds, up to twenty `silences` as `[from, to]` pairs, the median
  spectral `centroid` and `flatness`, and `silent_throughout`.
- An `audio` file, `heard.wav`, at 16 kHz mono, for transcription. It holds at
  most `settings.transcribe` seconds, and a longer recording leaves a
  `transcript` note. The same limit bounds `signal`.
- Up to eight `frame` files, JPEGs 768 pixels wide, one for every eight seconds
  of video, each with `at` in seconds, for scene captions.

Skipping `signal`, `transcript`, or `scenes` leaves out that work.

## email

Handles `message/rfc822`, and needs no programs.

- `headers`: `from`, `to`, and `cc` as `Name <address>` lists, `subject`,
  `date` in RFC 3339, and `message_id`.
- `thread`: `ids`, the message's own ID, then `In-Reply-To`, then `References`.
- `attachments`: `filename`, `content_type`, and `size` for each attachment.
  Each one is also a `child` file, and so is a forwarded message.
- `text`: the headers, then the new text, then what it quotes under
  `## Earlier in the thread`. HTML is read as text with headings kept as `#`
  lines.
- `outline`: `Message from <sender>` at 0, and `Earlier in the thread` where it
  starts.

A file that does not parse as a message is read as plain text. Parts nest at
most ten deep, a message holds at most 500 parts and 100 attachments, and
attachments stop at 256 MiB each and 1 GiB in all.

## epub

Handles `application/epub+zip`, and needs no programs.

- `book`: `title`, `publisher`, `date`, `language`, `identifier`,
  `description`, the lists `creators`, `contributors`, and `subjects`, the
  `chapters` in spine order, and the `encrypted` chapters.
- `text`: the book's details, then its chapters, a block to a line.

No entry is read past 8 MiB, and no book past 512 MiB unzipped.

## xlsx

Handles xlsx, xls, and ods. xlsx and ods are read directly. A legacy binary
xls is converted with `soffice` first, which needs LibreOffice Calc.

- `sheets`: for each sheet, `name`, `rows`, `columns`, `headers`, up to twenty
  `sample` rows, and `truncated`.
- `tables`: each sheet framed as `name`, `columns`, and up to 5,000 `rows`,
  with totals rows left out.
- `outline`: each sheet's `name`, `rows`, and `from`.
- `text`: each sheet's name, then its rows as cells joined by ` | `.

Numbers stay numbers, dates become `YYYY-MM-DD`, and text that only looks like
a number stays text. At most 30 columns and 200 characters a cell are kept,
and an ods row or cell repeated more than 10,000 times is counted without
being read again.
