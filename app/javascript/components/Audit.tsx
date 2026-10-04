import { Alert, Button, Code, Group, Loader, Stack, Text } from '@mantine/core'
import { AuditEventsDocument } from '@xixo/client'
import { useQuery } from '@xixo/client/react'
import { type CSSProperties, type ReactNode, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import {
  type Entry,
  type Happening,
  type Line,
  type Named,
  sorted,
  worst,
} from '../activity'
import { usePages } from '../hooks/usePages'
import { useTitle } from '../hooks/useTitle'
import { ago } from '../when'
import { Intro } from './Settings'

const PAGE = 50

const STATUSES = ['ok', 'denied', 'error']

const ACTORS: Record<string, string> = {
  person: 'people',
  agent: 'agents',
  client: 'clients',
  nobody: 'nobody',
}

const TONES: Record<string, string> = {
  ok: 'var(--ok)',
  denied: 'var(--brass)',
  error: 'var(--bad)',
}

const READING: Record<string, string> = {
  ok: 'allowed',
  denied: 'refused',
  error: 'failed',
}

const WRAPPED: CSSProperties = {
  display: 'block',
  whiteSpace: 'normal',
  overflowWrap: 'anywhere',
}

function who(event: Happening) {
  if (event.actor === 'person')
    return event.via
      ? `${event.actorName} through ${event.via}`
      : (event.actorName ?? 'someone')
  if (event.actor === 'client') return `client ${event.actorName ?? 'unnamed'}`
  if (event.actor === 'agent') return 'the agent'

  return 'nobody signed in'
}

function title(feed: Named) {
  return feed.title || feed.key
}

function tone(status: string) {
  return { '--tone': TONES[status] ?? 'var(--edge)' } as CSSProperties
}

function Chips<T extends string>({
  values,
  reading,
  held,
  toned,
  onPick,
}: {
  values: T[]
  reading: (value: T) => string
  held: T | null
  toned?: boolean
  onPick: (value: T | null) => void
}) {
  return (
    <Group gap="var(--s2)">
      {values.map((value) => (
        <button
          key={value}
          type="button"
          className="tag"
          data-dot={toned ? undefined : 'false'}
          style={{ ...(toned ? tone(value) : {}), cursor: 'pointer' }}
          data-on={held === value}
          aria-pressed={held === value}
          data-off={held !== null && held !== value}
          onClick={() => onPick(held === value ? null : value)}
        >
          {reading(value)}
        </button>
      ))}
    </Group>
  )
}

export function Audit() {
  useTitle('Activity')

  const [status, setStatus] = useState<string | null>(null)
  const [actor, setActor] = useState<string | null>(null)

  return (
    <Stack gap="var(--s5)">
      <Intro
        title="Activity"
        lead="Everything anyone asked xixo to do that needed permission: who asked, what they asked for, and whether it was allowed. Newest first. An agent's run is one entry, with its steps in the order it took them."
      />

      <Group gap="var(--s4)" align="center" wrap="wrap">
        <Chips
          values={STATUSES}
          reading={(value) => READING[value]}
          held={status}
          toned
          onPick={setStatus}
        />
        <Chips
          values={Object.keys(ACTORS)}
          reading={(value) => ACTORS[value]}
          held={actor}
          onPick={setActor}
        />
      </Group>

      <Trail
        key={`${status ?? ''} ${actor ?? ''}`}
        status={status}
        actor={actor}
      />
    </Stack>
  )
}

function Trail({
  status,
  actor,
}: {
  status: string | null
  actor: string | null
}) {
  const [cursor, setCursor] = useState<string | null>(null)
  const [, tick] = useState(0)

  useEffect(() => {
    const timer = window.setInterval(() => tick((count) => count + 1), 30_000)

    return () => window.clearInterval(timer)
  }, [])

  const { data, loading, error } = useQuery(AuditEventsDocument, {
    status,
    actor,
    feed: null,
    after: cursor,
    limit: PAGE,
  })

  const page = data?.auditEvents
  const [kept] = usePages<Happening>(
    page as { nodes: Happening[] } | undefined,
    cursor,
  )

  if (error) return <Alert color="red">{error.message}</Alert>
  if (loading && kept.length === 0)
    return <Loader size="sm" color="var(--brass)" />

  if (kept.length === 0) {
    return (
      <Text c="dimmed" size="sm">
        {status || actor
          ? 'Nothing matches that.'
          : 'Nothing has been asked of xixo yet. Sync a resource or point a client at /mcp and it will fill up.'}
      </Text>
    )
  }

  return (
    <Stack gap="var(--s4)">
      <div className="panel">
        {sorted(kept).map((entry) => (
          <Told key={entry.key} entry={entry} />
        ))}
      </div>

      {page?.hasMore && (
        <Group justify="center">
          <Button
            variant="default"
            radius="xl"
            loading={loading}
            onClick={() => setCursor(page.nextCursor ?? null)}
          >
            Load more
          </Button>
        </Group>
      )}
    </Stack>
  )
}

function Told({ entry }: { entry: Entry }) {
  return entry.kind === 'run' ? (
    <Run entry={entry} />
  ) : (
    <One line={entry.line} />
  )
}

function When({
  at,
  open,
  onToggle,
}: {
  at: string
  open: boolean
  onToggle?: () => void
}) {
  return (
    <Group gap="var(--s3)" wrap="nowrap" align="center">
      <Text
        size="xs"
        c="dimmed"
        className="when"
        title={new Date(at).toLocaleString()}
      >
        {ago(at)}
      </Text>
      {onToggle && (
        <button
          type="button"
          className="tag"
          data-dot="false"
          data-on={open}
          aria-expanded={open}
          style={{ cursor: 'pointer' }}
          onClick={onToggle}
        >
          {open ? 'hide' : 'why'}
        </button>
      )}
    </Group>
  )
}

function Why({ event }: { event: Happening }) {
  const asked = Object.keys(event.arguments ?? {}).length > 0

  return (
    <Stack gap="var(--s2)" mt="var(--s2)">
      {asked && (
        <Code block className="fallen-why">
          {JSON.stringify(event.arguments, null, 2)}
        </Code>
      )}
      <Text size="xs" c="dimmed" className="mono">
        {[
          event.channel,
          event.action,
          event.scope,
          new Date(event.createdAt).toLocaleString(),
          event.requestId && `request ${event.requestId}`,
        ]
          .filter(Boolean)
          .join(' · ')}
      </Text>
    </Stack>
  )
}

function Refusal({ event }: { event: Happening }) {
  if (!event.detail) return null

  return (
    <Text
      size="xs"
      mt="var(--s1)"
      style={{ color: event.status === 'ok' ? 'var(--soft)' : 'var(--bad)' }}
    >
      {event.detail}
    </Text>
  )
}

function Said({ line }: { line: Line }) {
  const { event, times } = line

  return (
    <>
      {event.told ?? event.action}
      {times > 1 && <span className="figure"> ×{times}</span>}
    </>
  )
}

function Status({ status }: { status: string }) {
  if (status === 'ok') return null

  return (
    <span className="tag" style={tone(status)}>
      {READING[status] ?? status}
    </span>
  )
}

function FeedLink({ feed, children }: { feed: Named; children?: ReactNode }) {
  return (
    <Link to={`/items/${feed.id}`} style={{ color: 'var(--brass)' }}>
      {children ?? title(feed)}
    </Link>
  )
}

function One({ line }: { line: Line }) {
  const [open, setOpen] = useState(false)
  const { event } = line

  return (
    <div className="entry" data-spine="true" style={tone(event.status)}>
      <div style={{ minWidth: 0 }}>
        <Group gap="var(--s2)" wrap="wrap">
          <span className="entry-title" style={WRAPPED}>
            <Said line={line} />
          </span>
          <Status status={event.status} />
        </Group>

        <Text size="xs" c="dimmed" mt="var(--s2)">
          {who(event)}
          {event.remoteIp ? ` · ${event.remoteIp}` : ''}
          {typeof event.durationMs === 'number'
            ? ` · ${event.durationMs}ms`
            : ''}
          {event.feed && (
            <>
              {' · '}
              <FeedLink feed={event.feed} />
            </>
          )}
        </Text>

        <Refusal event={event} />
        {open && <Why event={event} />}
      </div>

      <When at={event.createdAt} open={open} onToggle={() => setOpen(!open)} />
    </div>
  )
}

function Run({ entry }: { entry: Extract<Entry, { kind: 'run' }> }) {
  const [open, setOpen] = useState(false)
  const events = entry.lines.map((line) => line.event)
  const status = worst(events.map((event) => event.status))
  const spent = events.reduce((sum, event) => sum + (event.durationMs ?? 0), 0)
  const failed = events.filter((event) => event.status !== 'ok').length
  const newest = events.at(-1)?.createdAt ?? ''
  const doing = entry.cause === 'ask' ? 'answering' : 'analyzing'

  return (
    <div className="entry" data-spine="true" style={tone(status)}>
      <div style={{ minWidth: 0 }}>
        <span className="entry-title" style={WRAPPED}>
          The agent {doing}{' '}
          {entry.feed ? <FeedLink feed={entry.feed} /> : 'a feed that is gone'}
        </span>

        <Text size="xs" c="dimmed" mt="var(--s2)">
          {events.length} {events.length === 1 ? 'call' : 'calls'} · {spent}ms
          {failed > 0 ? ` · ${failed} did not go through` : ''}
        </Text>

        <Stack gap="var(--s2)" mt="var(--s3)">
          {entry.lines.map((line) => (
            <div
              key={line.event.id}
              style={{
                display: 'flex',
                gap: 'var(--s2)',
                alignItems: 'baseline',
              }}
            >
              <span
                role="img"
                aria-label={READING[line.event.status] ?? line.event.status}
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: 999,
                  flex: 'none',
                  background: TONES[line.event.status] ?? 'var(--edge)',
                  transform: 'translateY(-1px)',
                }}
              />
              <div style={{ minWidth: 0 }}>
                <Text size="sm">
                  <Said line={line} />
                </Text>
                <Refusal event={line.event} />
                {open && <Why event={line.event} />}
              </div>
            </div>
          ))}
        </Stack>
      </div>

      <When at={newest} open={open} onToggle={() => setOpen(!open)} />
    </div>
  )
}
