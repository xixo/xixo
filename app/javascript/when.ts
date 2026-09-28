const DAY = 86400

export function ago(at: string) {
  const seconds = Math.round((Date.now() - new Date(at).getTime()) / 1000)

  if (seconds < 60) return 'just now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < DAY) return `${Math.floor(seconds / 3600)}h ago`

  return `${Math.floor(seconds / DAY)}d ago`
}

export function dated(at: string) {
  const then = new Date(at)
  const seconds = (Date.now() - then.getTime()) / 1000

  if (seconds < 7 * DAY) return ago(at)

  const sameYear = then.getFullYear() === new Date().getFullYear()

  return then.toLocaleDateString(undefined, {
    month: 'short',
    day: sameYear ? 'numeric' : undefined,
    year: sameYear ? undefined : 'numeric',
  })
}
