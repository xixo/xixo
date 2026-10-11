import { useSyncExternalStore } from 'react'

const listeners = new Set<() => void>()
let live = true

export function cableChanged(open: boolean) {
  live = open
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  window.addEventListener('online', listener)
  window.addEventListener('offline', listener)

  return () => {
    listeners.delete(listener)
    window.removeEventListener('online', listener)
    window.removeEventListener('offline', listener)
  }
}

function snapshot() {
  if (!navigator.onLine) return 'offline'
  return live ? 'live' : 'dropped'
}

export function useConnection() {
  return useSyncExternalStore(subscribe, snapshot)
}
