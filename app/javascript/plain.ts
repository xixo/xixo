import { ago } from './when'

export interface Plain {
  type: string
  key: string
  capabilities: string[]
}

export interface Health {
  connected: boolean
  seenAt?: string | null
  uptime?: number | null
  memoryTotal?: number | string | null
  memoryAvailable?: number | string | null
  disks?: {
    path: string
    total?: number | string | null
    free?: number | string | null
  }[]
}

const DOES: Record<string, string> = {
  database: 'Files kept inside xixo',
  s3: 'A storage bucket',
  webdav: 'A shared drive',
  'oauth-google': 'Your Google Drive',
  'microsoft-graph': 'Your OneDrive',
  'openai-compatible': 'A model server',
  tailnet: 'A private network to your machines',
  imap: 'Your email',
  caldav: 'Your calendars',
  carddav: 'Your contacts',
  rss: 'A news feed',
  web: 'Web pages you keep',
  search: 'Web search for agents',
  curl: 'Fetches web pages for agents',
  weather: 'The weather, for agents',
  places: 'Places on a map, for agents',
  mcp: 'Tools from another app',
  github: 'Your GitHub',
  notion: 'Your Notion',
  slack: 'Your Slack',
  git: 'A git repository',
}

export function does(resource: Plain) {
  if (resource.type === 'machine')
    return resource.key === 'local'
      ? 'Where xixo runs'
      : 'A machine running xixo link'
  if (resource.type === 'filesystem') return 'A folder'

  return (
    DOES[resource.type] ??
    (resource.capabilities.includes('storage')
      ? 'A place your files live'
      : resource.capabilities.includes('inference')
        ? 'Models that read and answer'
        : 'A tool agents can use')
  )
}

const PLAIN_ERRORS: [RegExp, string][] = [
  [
    /link beside the server has not enrolled yet/,
    "xixo link on this server hasn't connected yet",
  ],
  [
    /the machine is not linked/,
    "The machine isn't linked. Run the link-up command on it again",
  ],
  [/link has never connected/, "The machine hasn't connected yet"],
  [/link was last heard from/, "The machine isn't connected"],
  [/not connected to masks/, "This xixo isn't connected to masks"],
]

export function humane(error: string) {
  return (
    PLAIN_ERRORS.find(([pattern]) => pattern.test(error))?.[1] ??
    "It didn't answer when xixo last checked"
  )
}

const KINDS: [string, string][] = [
  ['pdf', 'PDFs'],
  ['image', 'photos'],
  ['media', 'audio and video'],
  ['doc', 'office documents'],
  ['xlsx', 'spreadsheets'],
  ['epub', 'books'],
  ['email', 'email'],
  ['calendar', 'calendars'],
  ['contact', 'contacts'],
  ['pkpass', 'passes'],
  ['data', 'data files'],
  ['text', 'text'],
]

export function reads(extractors: string[], unread: string[]) {
  if (extractors.length === 0) return 'Reads nothing yet'
  if (unread.length === 0) return 'Reads every kind of file'

  const named = KINDS.filter(([kind]) => extractors.includes(kind)).map(
    ([, plain]) => plain,
  )
  const shown = named.slice(0, 2)
  const more = named.length - shown.length

  return `Reads ${shown.join(', ')}${more > 0 ? `, and ${more} more` : ''}`
}

export function cannotRead(unread: string[]) {
  return KINDS.filter(([kind]) => unread.includes(kind))
    .map(([, plain]) => plain)
    .join(', ')
}

export interface Waiting {
  kind?: string | null
  count: number
}

function files(count: number) {
  return `${count.toLocaleString()} ${count === 1 ? 'file waits' : 'files wait'}`
}

function kindsOf(waiting: Waiting[]) {
  const named = KINDS.filter(([kind]) =>
    waiting.some((held) => held.kind === kind),
  ).map(([, plain]) => plain)

  if (named.length < 2) return named.join('')

  return `${named.slice(0, -1).join(', ')} or ${named[named.length - 1]}`
}

export function waitingOn(waiting: Waiting[], connected: boolean) {
  const count = waiting.reduce((sum, held) => sum + held.count, 0)

  if (count === 0) return null
  if (!connected) return `${files(count)} for it to come back`

  const kinds = kindsOf(waiting)

  return kinds ? `${files(count)} for it to read ${kinds}` : files(count)
}

export function waitingForAny(waiting: Waiting[]) {
  const count = waiting.reduce((sum, held) => sum + held.count, 0)

  if (count === 0) return null

  const kinds = kindsOf(waiting)

  return `${files(count)} for a machine that reads ${kinds || 'them'}`
}

function bytes(value?: number | string | null) {
  const held = Number(value)
  return Number.isFinite(held) && held > 0 ? held : null
}

function size(value: number) {
  const gigabytes = value / 1024 ** 3

  return gigabytes >= 1000
    ? `${(gigabytes / 1024).toFixed(1)} TB`
    : `${gigabytes >= 10 ? Math.round(gigabytes) : gigabytes.toFixed(1)} GB`
}

export function sized(value?: number | string | null) {
  const held = bytes(value)
  return held ? size(held) : null
}

export function upFor(seconds?: number | null) {
  if (seconds == null) return null

  const days = Math.floor(seconds / 86400)
  if (days >= 1) return `up ${days} ${days === 1 ? 'day' : 'days'}`

  const hours = Math.floor(seconds / 3600)
  return hours >= 1
    ? `up ${hours} ${hours === 1 ? 'hour' : 'hours'}`
    : 'just started'
}

export function memory(health: Health) {
  const total = bytes(health.memoryTotal)
  const free = bytes(health.memoryAvailable)

  return total && free ? `${size(free)} of ${size(total)} memory free` : null
}

export function disks(health: Health) {
  return (health.disks ?? []).flatMap((disk) => {
    const total = bytes(disk.total)
    const free = bytes(disk.free)

    return total && free !== null
      ? [`${disk.path}: ${size(free)} of ${size(total)} free`]
      : []
  })
}

export function warning(health: Health) {
  if (!health.connected) return null

  const low = (health.disks ?? []).find((disk) => {
    const total = bytes(disk.total)
    const free = bytes(disk.free) ?? 0
    return total !== null && free / total < 0.05
  })
  if (low) return `Almost out of space on ${low.path}`

  const total = bytes(health.memoryTotal)
  const free = bytes(health.memoryAvailable)
  if (total && free !== null && free / total < 0.05)
    return 'Almost out of memory'

  return null
}

export function lastSeen(health: Health) {
  if (health.connected) return null

  return health.seenAt ? `last seen ${ago(health.seenAt)}` : 'never seen'
}
