export const SYSTEMS: Record<string, string> = {
  darwin: 'macOS',
  linux: 'Linux',
}

export const FOLDERS: Record<string, string[]> = {
  darwin: ['~/Documents', '~/Desktop'],
  linux: [],
}

const PLAIN = /^[A-Za-z0-9_./:@%+=,-]+$/

export function quoted(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

export function argument(folder: string) {
  if (folder === '~' || PLAIN.test(folder)) return folder
  if (folder.startsWith('~/')) {
    const rest = folder.slice(2)
    return PLAIN.test(rest) ? folder : `~/${quoted(rest)}`
  }

  return quoted(folder)
}

export function folderList(text: string) {
  const found: string[] = []
  const pattern = /'([^']*)'|"([^"]*)"|(\S+)/g

  for (const match of text.matchAll(pattern)) {
    const held = match[1] ?? match[2] ?? match[3]
    if (held) found.push(held)
  }

  return found
}

export function command(xixo: string, folders: readonly string[]) {
  const piped = `curl -fsSL ${xixo}/link.sh | sh`

  return folders.length > 0
    ? `${piped} -s -- ${folders.map(argument).join(' ')}`
    : piped
}

export const WRITABLE = ':rw'

export function listed(items: readonly string[]) {
  if (items.length <= 2) return items.join(' and ')

  return `${items.slice(0, -1).join(', ')}, and ${items[items.length - 1]}`
}

export function sharing(folders: readonly string[]) {
  if (folders.length === 0) return 'Shares no folders yet.'

  const named = folders.map((folder) =>
    folder.endsWith(WRITABLE)
      ? `${folder.slice(0, -WRITABLE.length)} (read and write)`
      : folder,
  )

  return `Shares ${listed(named)}.`
}

export function detected(systems: readonly string[], agent: string) {
  const offered = systems.filter((system) => system in SYSTEMS)
  const guessed = /Mac OS X|Macintosh/.test(agent) ? 'darwin' : 'linux'

  return offered.includes(guessed) ? guessed : (offered[0] ?? guessed)
}

export function systemOf(os?: string | null, arch?: string | null) {
  return [os ? (SYSTEMS[os] ?? os) : null, arch].filter(Boolean).join(' · ')
}
