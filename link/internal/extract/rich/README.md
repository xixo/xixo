# rich

The `media`, `email`, `epub`, and `xlsx` extractors. Each registers with
`extract` when the package is imported. Offsets in an outline count characters.

## media

Reads every `audio/*` and `video/*` type with `ffmpeg` and `ffprobe`.

- `probe`: the container's format, duration, bit rate, up to eight streams, and
  tags such as title, artist, and album.
- `signal`, for audio: loudness, loudness range, peak, silences, and the
  spectrum's centroid and flatness.
- An `audio` file, `heard.wav`, at 16 kHz mono for transcription, holding at
  most `settings.transcribe` seconds.
- For video, up to eight `frame` files, JPEGs 768 pixels wide, one for every
  eight seconds, each with `at` in seconds, for scene captions.

`skip` with `signal`, `transcript`, or `scenes` leaves out that work.

On a Mac without ffmpeg, the mac reader answers with the same steps through
AVFoundation, with ffmpeg's names for codecs and containers.

## email

Reads `message/rfc822` with no outside program.

- `headers`: `from`, `to`, `cc`, `subject`, `date`, and `message_id`.
- `thread`: the message's own ID, then `In-Reply-To`, then `References`.
- `attachments`: the name, type, and size of each attachment. Each attachment,
  and each forwarded message, is also a `child` file.
- `text`: the headers, the new text, then what it quotes under
  `## Earlier in the thread`.
- `outline`: the message, and where the quoted text starts.

A file that does not parse as a message is read as plain text.

## epub

Reads `application/epub+zip` with no outside program.

- `book`: the title, publisher, date, language, identifier, description,
  creators, contributors, subjects, chapters in reading order, and encrypted
  chapters.
- `text`: the book's details, then its chapters.

## xlsx

Reads `.xlsx` and `.ods` directly. A legacy `.xls` is converted with `soffice`
first, which needs LibreOffice Calc.

- `sheets`: each sheet's name, size, headers, and up to twenty sample rows.
- `tables`: each sheet as columns and up to 5,000 rows, with totals rows left
  out.
- `outline`: one section for each sheet.
- `text`: each sheet's name, then its rows as cells joined by ` | `.

Numbers stay numbers, dates become `YYYY-MM-DD`, and text that only looks like
a number stays text.
