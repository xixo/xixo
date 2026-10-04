export const RUN_TONES: Record<string, string> = {
  queued: 'var(--edge)',
  running: 'var(--busy)',
  done: 'var(--ok)',
  failed: 'var(--bad)',
  cancelled: 'var(--edge)',
  gated: 'var(--accent)',
}

export const RUN_OPEN = new Set(['queued', 'running'])

export const TONE_FOR_LINE: Record<string, string> = {
  '[x]': 'var(--bad)',
  '[✓]': 'var(--ok)',
  '[-]': 'var(--muted)',
}
