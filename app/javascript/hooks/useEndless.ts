import { type RefObject, useEffect, useRef } from 'react'

export function useEndless(
  more: () => void,
  enabled: boolean,
  ahead = 800,
): RefObject<HTMLDivElement | null> {
  const edge = useRef<HTMLDivElement | null>(null)
  const latest = useRef(more)

  latest.current = more

  useEffect(() => {
    const held = edge.current

    if (!enabled || !held || typeof IntersectionObserver === 'undefined') {
      return
    }

    const watch = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) latest.current()
      },
      { rootMargin: `0px 0px ${ahead}px 0px` },
    )

    watch.observe(held)

    return () => watch.disconnect()
  }, [enabled, ahead])

  return edge
}
