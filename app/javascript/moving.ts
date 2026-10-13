export interface Moved {
  files: number
  filesDone: number
  filesFailed: number
  bytes: unknown
  bytesDone: unknown
}

const UNITS = ['bytes', 'KB', 'MB', 'GB', 'TB']

export function amount(value: unknown) {
  let held = Math.max(0, Number(value) || 0)
  let unit = 0

  while (held >= 1024 && unit < UNITS.length - 1) {
    held /= 1024
    unit += 1
  }

  if (unit === 0) return `${held} ${held === 1 ? 'byte' : 'bytes'}`

  return `${held >= 10 ? Math.round(held) : held.toFixed(1)} ${UNITS[unit]}`
}

export function share(moved: Moved | null | undefined) {
  if (!moved) return 0

  const bytes = Number(moved.bytes)
  if (bytes > 0) return Math.min(100, (Number(moved.bytesDone) / bytes) * 100)
  if (moved.files > 0)
    return Math.min(100, (moved.filesDone / moved.files) * 100)

  return 0
}

export function movedSoFar(moved: Moved | null | undefined) {
  if (!moved || moved.files === 0) return 'Looking for the files to move.'

  const files = `${moved.filesDone.toLocaleString()} of ${moved.files.toLocaleString()} ${moved.files === 1 ? 'file' : 'files'}`
  const bytes = `${amount(moved.bytesDone)} of ${amount(moved.bytes)}`
  const stayed =
    moved.filesFailed > 0
      ? `. ${moved.filesFailed.toLocaleString()} stayed where ${moved.filesFailed === 1 ? 'it was' : 'they were'}`
      : ''

  return `${files} moved, ${bytes}${stayed}.`
}
