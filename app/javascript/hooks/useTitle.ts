import { useEffect } from 'react'

export function useTitle(what?: string | null) {
  useEffect(() => {
    document.title = what ? `${what} · xixo` : 'xixo'
  }, [what])
}
