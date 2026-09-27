import { type ReactNode, useLayoutEffect, useRef, useState } from 'react'

export function OneLine({
  children,
  className,
  noun,
}: {
  children: ReactNode
  className: string
  noun: string
}) {
  const list = useRef<HTMLDivElement>(null)
  const [open, setOpen] = useState(false)
  const [row, setRow] = useState<number>()
  const [below, setBelow] = useState(0)

  useLayoutEffect(() => {
    const held = list.current
    if (!held) return

    const measure = () => {
      const items = [...held.children] as HTMLElement[]
      const first = items[0]
      if (!first) return

      setRow(first.offsetHeight)
      setBelow(items.filter((item) => item.offsetTop > first.offsetTop).length)
    }

    measure()
    const resized = new ResizeObserver(measure)
    const changed = new MutationObserver(measure)
    resized.observe(held)
    changed.observe(held, { childList: true })
    return () => {
      resized.disconnect()
      changed.disconnect()
    }
  }, [])

  return (
    <div className="one-line">
      <div
        ref={list}
        className={className}
        style={
          open || !row ? undefined : { maxHeight: row, overflow: 'hidden' }
        }
      >
        {children}
      </div>
      {below > 0 && (
        <button
          type="button"
          className="one-line-more"
          aria-expanded={open}
          aria-label={
            open ? `Show fewer ${noun}` : `Show ${below} more ${noun}`
          }
          onClick={() => setOpen(!open)}
        >
          {open ? 'Fewer' : `+${below} more`}
        </button>
      )}
    </div>
  )
}
