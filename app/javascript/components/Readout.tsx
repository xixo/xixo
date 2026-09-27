import { useState } from 'react'

export interface Detail {
  group: string
  step: string
  item?: number | null
  label: string
  value: string
}

const FOLDED = 12

export function Readout({ details }: { details: readonly Detail[] }) {
  const groups = new Map<string, Detail[]>()

  for (const detail of details) {
    const held = groups.get(detail.group) ?? []
    held.push(detail)
    groups.set(detail.group, held)
  }

  return (
    <div className="panel readout">
      {[...groups].map(([group, rows]) => (
        <Group key={group} name={group} rows={rows} />
      ))}
    </div>
  )
}

function Group({ name, rows }: { name: string; rows: Detail[] }) {
  const [open, setOpen] = useState(false)
  const folded = !open && rows.length > FOLDED
  const shown = folded ? rows.slice(0, FOLDED) : rows

  return (
    <section
      className="readout-group"
      data-wide={rows.length > FOLDED ? 'true' : 'false'}
    >
      <h3 className="label readout-name">{name}</h3>
      <dl className="readout-list">
        {shown.map((row, index) => (
          <div
            key={`${row.item ?? 0}-${row.label}-${row.value}`}
            className="readout-row"
            data-starts={
              index > 0 &&
              row.item != null &&
              row.item !== shown[index - 1].item
                ? 'true'
                : 'false'
            }
          >
            <dt>
              {row.item != null ? `${row.item} · ${row.label}` : row.label}
            </dt>
            <dd>{row.value}</dd>
          </div>
        ))}
      </dl>
      {rows.length > FOLDED && (
        <button
          type="button"
          className="readout-more"
          onClick={() => setOpen(!open)}
        >
          {open ? 'Show fewer' : `Show all ${rows.length}`}
        </button>
      )}
    </section>
  )
}
