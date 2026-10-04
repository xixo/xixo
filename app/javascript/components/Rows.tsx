import { Checkbox } from '@mantine/core'
import type { RowFragment } from '@xixo/client'
import { Link } from 'react-router-dom'
import { hrefFor, lookOf, toned } from '../looks'
import { dated } from '../when'
import { Cover, Thumb } from './Thumb'

export type Row = RowFragment

export type View = 'list' | 'cards'

interface Pick {
  chosen: ReadonlySet<string>
  toggle: (id: string) => void
  pickable: (row: Row) => boolean
}

function Within({ row }: { row: Row }) {
  if (!row.parent) return null

  return (
    <div className="entry-within">in {row.parent.title ?? row.parent.key}</div>
  )
}

function Gist({ row, className }: { row: Row; className: string }) {
  if (row.summary) return <div className={className}>{row.summary}</div>
  if (row.staged)
    return <div className={className}>Waiting for somewhere to live</div>
  if (!row.analyzedAt && row.type === 'xixo:file') {
    return <div className={className}>Not analyzed yet</div>
  }

  return null
}

function Side({ row }: { row: Row }) {
  const { tone, label } = lookOf(row)

  return (
    <div className="entry-side" style={toned(tone)}>
      <span className="entry-kind">{label}</span>
      <time className="entry-when" dateTime={row.createdAt}>
        {dated(row.createdAt)}
      </time>
    </div>
  )
}

function named(row: Row) {
  return row.title ?? row.key ?? 'Untitled'
}

export function Rows({
  rows,
  view = 'list',
  pick,
}: {
  rows: Row[]
  view?: View
  pick?: Pick
}) {
  if (view === 'cards') {
    return (
      <>
        {rows.length > 0 && (
          <div className="grid">
            {rows.map((row) => (
              <Link key={row.id} to={hrefFor(row)} className="card">
                <Cover url={row.thumbnailUrl} looked={row} alt={named(row)} />
                <div className="card-body">
                  <div className="card-title">{named(row)}</div>
                  <Within row={row} />
                  <Gist row={row} className="card-summary" />
                  <div className="card-foot">
                    <Side row={row} />
                  </div>
                </div>
              </Link>
            ))}
          </div>
        )}
      </>
    )
  }

  if (rows.length === 0) return null

  return (
    <div className="panel">
      {rows.map((row) => (
        <Entry key={row.id} row={row} pick={pick} />
      ))}
    </div>
  )
}

function Entry({ row, pick }: { row: Row; pick?: Pick }) {
  const entry = (
    <Link
      to={hrefFor(row)}
      className="entry"
      style={toned(lookOf(row).tone)}
      data-picked={pick?.chosen.has(row.id) || undefined}
    >
      <Thumb url={row.thumbnailUrl} looked={row} alt="" size={44} />
      <div className="entry-copy">
        <div className="entry-title">{named(row)}</div>
        <Within row={row} />
        <Gist row={row} className="entry-summary" />
      </div>
      <Side row={row} />
    </Link>
  )

  if (!pick) return entry

  return (
    <div className="entry-pick">
      <Checkbox
        color="brand"
        checked={pick.chosen.has(row.id)}
        disabled={!pick.pickable(row)}
        onChange={() => pick.toggle(row.id)}
        aria-label={`Select ${named(row)}`}
      />
      {entry}
    </div>
  )
}
