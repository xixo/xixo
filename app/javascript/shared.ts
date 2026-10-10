export interface Told {
  text: string
  wrong?: boolean
}

export const SHARED_KEYS = ['shared', 'kept', 'twins', 'refused'] as const

function count(params: URLSearchParams, key: string): number {
  const held = Number.parseInt(params.get(key) ?? '', 10)

  return Number.isFinite(held) && held > 0 ? held : 0
}

function files(n: number): string {
  return n === 1 ? '1 file' : `${n} files`
}

function filesTold(params: URLSearchParams): Told {
  const kept = count(params, 'kept')
  const twins = count(params, 'twins')
  const refused = count(params, 'refused')
  const parts: string[] = []

  if (kept) parts.push(`${files(kept)} kept`)
  if (twins) parts.push(`${files(twins)} already here`)
  if (refused) parts.push(`${files(refused)} with nowhere to go`)

  if (parts.length === 0) return { text: 'Nothing came with that share.' }

  return {
    text: `Shared to xixo: ${parts.join(', ')}.`,
    wrong: kept === 0 && twins === 0,
  }
}

export function toldOfShare(params: URLSearchParams): Told | null {
  switch (params.get('shared')) {
    case 'kept':
      return { text: 'The file is kept. It is being read now.' }
    case 'twin':
      return { text: 'That file was already here.' }
    case 'note':
      return { text: 'The note is kept.' }
    case 'page':
      return { text: 'The page is being rendered.' }
    case 'download':
      return { text: 'The file at that address is being fetched.' }
    case 'files':
      return filesTold(params)
    case 'nothing':
      return { text: 'Nothing came with that share.', wrong: true }
    case 'refused':
      return {
        text: 'That share could not be kept. Check that storage is attached on Resources.',
        wrong: true,
      }
    case 'denied':
      return {
        text: 'Your sign-in may read the catalog but not add to it.',
        wrong: true,
      }
    default:
      return null
  }
}
