import type { RowFragment } from '@uris-to/client'
import { Link } from 'react-router-dom'
import { hrefFor } from '../looks'
import { Cover, Thumb } from './Thumb'
import { TypeBadge } from './TypeBadge'

export type Row = RowFragment

export type View = 'list' | 'cards'

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
  if (!row.analyzedAt && row.type === 'uris:file') {
    return <div className={className}>Not analyzed yet</div>
  }

  return null
}

function named(row: Row) {
  return row.title ?? row.key ?? 'Untitled'
}

export function Rows({ rows, view = 'list' }: { rows: Row[]; view?: View }) {
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
                    <TypeBadge type={row.type} mime={row.mime} />
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
        <Link key={row.id} to={hrefFor(row)} className="entry">
          <Thumb
            url={row.thumbnailUrl}
            looked={row}
            alt={named(row)}
            size={48}
          />
          <div style={{ minWidth: 0 }}>
            <div className="entry-title">{named(row)}</div>
            <Within row={row} />
            <Gist row={row} className="entry-summary" />
          </div>
          <TypeBadge type={row.type} mime={row.mime} />
        </Link>
      ))}
    </div>
  )
}
