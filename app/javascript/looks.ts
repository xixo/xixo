import {
  IconBraces,
  IconCalendarEvent,
  IconFile,
  IconFileSpreadsheet,
  IconFileText,
  IconFileTypeDoc,
  IconFileTypePdf,
  IconMail,
  IconMovie,
  IconMusic,
  IconNote,
  IconPhoto,
  IconRadar,
  IconTable,
  IconTag,
  IconTicket,
  IconUser,
  IconWorld,
} from '@tabler/icons-react'
import type { CSSProperties } from 'react'

export const TYPE = {
  file: 'uris:file',
  note: 'uris:note',
  address: 'uris:address',
  tag: 'uris:tag',
  mime: 'uris:mime',
} as const

export type Short = keyof typeof TYPE

export const KEPT: string[] = [TYPE.file, TYPE.note]

const PLURAL: Record<Short, string> = {
  file: 'files',
  note: 'notes',
  address: 'addresses',
  tag: 'tags',
  mime: 'content types',
}

export const FAMILIES = [
  'pdf',
  'email',
  'xlsx',
  'contact',
  'data',
  'calendar',
  'text',
  'doc',
  'audio',
  'video',
  'image',
  'page',
  'pkpass',
  'file',
] as const

export type Family = (typeof FAMILIES)[number]

const GLYPHS: Record<string, typeof IconFile> = {
  pdf: IconFileTypePdf,
  image: IconPhoto,
  text: IconFileText,
  data: IconTable,
  email: IconMail,
  xlsx: IconFileSpreadsheet,
  doc: IconFileTypeDoc,
  audio: IconMusic,
  video: IconMovie,
  calendar: IconCalendarEvent,
  contact: IconUser,
  page: IconWorld,
  pkpass: IconTicket,
  file: IconFile,
  [TYPE.note]: IconNote,
  [TYPE.address]: IconRadar,
  [TYPE.tag]: IconTag,
  [TYPE.mime]: IconBraces,
}

const TONES: Record<string, string> = {
  [TYPE.note]: 'var(--k-text)',
  [TYPE.address]: 'var(--brass)',
  [TYPE.tag]: 'var(--soft)',
  [TYPE.mime]: 'var(--muted)',
}

const LABELS: Record<string, string> = {
  [TYPE.note]: 'note',
  [TYPE.address]: 'address',
  [TYPE.tag]: 'tag',
  [TYPE.mime]: 'content type',
}

const SHEETS = new Set([
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-excel',
  'application/vnd.oasis.opendocument.spreadsheet',
])

const DOCS = new Set([
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.oasis.opendocument.text',
])

const DATA = new Set([
  'application/json',
  'application/xml',
  'text/csv',
  'text/tab-separated-values',
])

export function familyOf(mime?: string | null): Family {
  const held = (mime ?? '').toLowerCase()

  if (held === 'application/pdf') return 'pdf'
  if (held === 'message/rfc822') return 'email'
  if (held === 'text/calendar') return 'calendar'
  if (held === 'text/vcard') return 'contact'
  if (held === 'application/vnd.apple.pkpass') return 'pkpass'
  if (held === 'uris/page' || held === 'uris/entry') return 'page'
  if (SHEETS.has(held)) return 'xlsx'
  if (DOCS.has(held)) return 'doc'
  if (DATA.has(held)) return 'data'
  if (held.startsWith('image/')) return 'image'
  if (held.startsWith('video/')) return 'video'
  if (held.startsWith('audio/')) return 'audio'
  if (held.startsWith('text/')) return 'text'

  return 'file'
}

export interface Looked {
  type: string
  mime?: string | null
}

export interface Look {
  tone: string
  glyph: typeof IconFile
  label: string
}

export function lookOf({ type, mime }: Looked): Look {
  if (type !== TYPE.file && TONES[type]) {
    return { tone: TONES[type], glyph: GLYPHS[type], label: LABELS[type] }
  }

  const family = familyOf(mime)

  return { tone: toneOf(family), glyph: GLYPHS[family], label: family }
}

export function toneOf(family: string): string {
  return (FAMILIES as readonly string[]).includes(family)
    ? `var(--k-${family})`
    : 'var(--k-file)'
}

export function toned(tone: string): CSSProperties {
  return { '--tone': tone } as CSSProperties
}

export function shortOf(type: string | null | undefined): Short | null {
  const found = Object.entries(TYPE).find(([, full]) => full === type)

  return found ? (found[0] as Short) : null
}

export function pluralOf(type: string): string {
  const short = shortOf(type)

  return short ? PLURAL[short] : type
}

export function hrefFor(feed: {
  id: string
  type: string
  key?: string | null
}) {
  if (feed.type === TYPE.address && feed.key)
    return `/${feed.key.replace(/^\//, '')}`

  return `/items/${feed.id}`
}
