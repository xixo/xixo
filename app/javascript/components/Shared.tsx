import { useEffect } from 'react'
import { useSearchParams } from 'react-router-dom'
import { SHARED_KEYS, toldOfShare } from '../shared'
import { useSay } from './Say'

export function Shared() {
  const [params, setParams] = useSearchParams()
  const say = useSay()

  useEffect(() => {
    const told = toldOfShare(params)

    if (!told) return

    say(told)

    const rest = new URLSearchParams(params)

    for (const key of SHARED_KEYS) rest.delete(key)

    setParams(rest, { replace: true })
  }, [params, setParams, say])

  return null
}
