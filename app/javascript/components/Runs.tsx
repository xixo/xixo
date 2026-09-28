import { Alert, Button, Group, Loader, Stack, Table, Text } from '@mantine/core'
import {
  CancelRunDocument,
  RunProgressedDocument,
  RunsDocument,
} from '@uris-to/client'
import { useQuery, useSubscription } from '@uris-to/client/react'
import { type CSSProperties, useEffect, useState } from 'react'
import { usePages } from '../hooks/usePages'
import { useTitle } from '../hooks/useTitle'
import { RUN_OPEN, RUN_TONES, RunLog } from './RunLog'
import { useAloud, useSay } from './Say'
import { Intro } from './Settings'

const PAGE = 50

const STATUSES = ['queued', 'running', 'done', 'failed', 'cancelled', 'gated']

interface Row {
  id: string
  kind: string
  status: string
  processed: number
  lines: number
  error?: string | null
  startedAt?: string | null
  finishedAt?: string | null
  createdAt: string
  resource?: { id: string; key: string } | null
}

function elapsed(startedAt?: string | null, finishedAt?: string | null) {
  if (!startedAt) return '—'

  const from = new Date(startedAt).getTime()
  const to = finishedAt ? new Date(finishedAt).getTime() : Date.now()
  const seconds = Math.max(0, Math.round((to - from) / 1000))

  return seconds < 60
    ? `${seconds}s`
    : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

export function Runs() {
  useTitle('Runs')

  const [status, setStatus] = useState<string | null>(null)

  return (
    <Stack gap="var(--s5)">
      <Intro
        title="Runs"
        lead="Work that outlives a single request — a sync, an export, a feed thinking. Anything still open reports itself as it goes."
      />

      <Group gap="var(--s2)">
        <button
          type="button"
          className="tag"
          data-dot="false"
          data-on={status === null}
          aria-pressed={status === null}
          style={{ cursor: 'pointer' }}
          onClick={() => setStatus(null)}
        >
          all
        </button>
        {STATUSES.map((value) => (
          <button
            key={value}
            type="button"
            className="tag"
            style={
              { '--tone': RUN_TONES[value], cursor: 'pointer' } as CSSProperties
            }
            data-on={status === value}
            aria-pressed={status === value}
            data-off={status !== null && status !== value}
            onClick={() => setStatus(status === value ? null : value)}
          >
            {value}
          </button>
        ))}
      </Group>

      <Ledger key={status ?? ''} status={status} />
    </Stack>
  )
}

function Ledger({ status }: { status: string | null }) {
  const say = useSay()
  const [cursor, setCursor] = useState<string | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  const [, tick] = useState(0)

  const { data, loading, error, refetch } = useQuery(RunsDocument, {
    status,
    after: cursor,
    limit: PAGE,
  })
  const cancel = useAloud(CancelRunDocument, 'That run could not be cancelled.')
  const { data: progressed } = useSubscription(RunProgressedDocument)

  const page = data?.runs
  const [rows, setRows] = usePages<Row>(
    page as { nodes: Row[] } | undefined,
    cursor,
  )

  const streamed = progressed?.runProgressed.run
  const live = streamed?.id === open ? (streamed?.logs ?? null) : null
  const busy = rows.some((run) => RUN_OPEN.has(run.status))

  useEffect(() => {
    if (!streamed) return

    setRows((held) => {
      const at = held.findIndex((run) => run.id === streamed.id)

      if (at < 0) return held

      const next = [...held]

      next[at] = {
        ...next[at],
        status: streamed.status,
        processed: streamed.processed,
        lines: streamed.lines,
        startedAt: streamed.startedAt,
        finishedAt: streamed.finishedAt,
      }

      return next
    })
  }, [streamed, setRows])

  useEffect(() => {
    if (!streamed || cursor) return
    if (rows.some((run) => run.id === streamed.id)) return

    refetch()
  }, [streamed, cursor, rows, refetch])

  useEffect(() => {
    if (!busy) return

    const timer = window.setInterval(() => tick((count) => count + 1), 1000)

    return () => window.clearInterval(timer)
  }, [busy])

  if (error) return <Alert color="red">{error.message}</Alert>
  if (loading && rows.length === 0) {
    return <Loader size="sm" color="var(--brass)" />
  }

  if (rows.length === 0) {
    return (
      <Text c="dimmed" size="sm">
        {status
          ? `Nothing is ${status}.`
          : 'Nothing has run yet. Sync a resource and it will show up here.'}
      </Text>
    )
  }

  return (
    <Stack gap="var(--s4)">
      <div className="panel">
        <Table.ScrollContainer minWidth={620} type="native">
          <Table verticalSpacing="sm" horizontalSpacing="lg">
            <Table.Thead>
              <Table.Tr>
                <Table.Th>Work</Table.Th>
                <Table.Th>Status</Table.Th>
                <Table.Th>Resource</Table.Th>
                <Table.Th>Processed</Table.Th>
                <Table.Th>Elapsed</Table.Th>
                <Table.Th />
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {rows.flatMap((run) => [
                <Table.Tr key={run.id}>
                  <Table.Td>
                    <Group gap="var(--s2)" wrap="nowrap">
                      {run.lines > 0 && (
                        <button
                          type="button"
                          className="tag"
                          data-dot="false"
                          data-on={open === run.id}
                          aria-expanded={open === run.id}
                          style={{ cursor: 'pointer' }}
                          onClick={() =>
                            setOpen(open === run.id ? null : run.id)
                          }
                        >
                          {open === run.id ? 'hide' : `${run.lines} lines`}
                        </button>
                      )}
                      <Text fw={600} size="sm">
                        {run.kind}
                      </Text>
                    </Group>
                    {run.error && (
                      <Text size="xs" style={{ color: 'var(--bad)' }}>
                        {run.error}
                      </Text>
                    )}
                  </Table.Td>
                  <Table.Td>
                    <span
                      className="tag"
                      style={
                        {
                          '--tone': RUN_TONES[run.status] ?? 'var(--edge)',
                        } as CSSProperties
                      }
                    >
                      {run.status}
                    </span>
                  </Table.Td>
                  <Table.Td>
                    <Text size="sm" c="dimmed">
                      {run.resource?.key ?? '—'}
                    </Text>
                  </Table.Td>
                  <Table.Td>
                    <span className="figure">
                      {run.processed.toLocaleString()}
                    </span>
                  </Table.Td>
                  <Table.Td>
                    <span className="figure" style={{ color: 'var(--muted)' }}>
                      {elapsed(run.startedAt, run.finishedAt)}
                    </span>
                  </Table.Td>
                  <Table.Td>
                    {RUN_OPEN.has(run.status) && (
                      <Button
                        size="compact-xs"
                        radius="xl"
                        variant="subtle"
                        color="red"
                        onClick={async () => {
                          const answered = await cancel.execute({ id: run.id })

                          if (!answered) return

                          const settled =
                            answered.cancelRun?.run.status ?? 'cancelled'

                          setRows((held) =>
                            held.map((row) =>
                              row.id === run.id
                                ? { ...row, status: settled }
                                : row,
                            ),
                          )
                          say({ text: `The ${run.kind} run was cancelled.` })
                        }}
                      >
                        Cancel
                      </Button>
                    )}
                  </Table.Td>
                </Table.Tr>,
                open === run.id ? (
                  <Table.Tr key={`${run.id}-log`}>
                    <Table.Td colSpan={6} style={{ paddingTop: 0 }}>
                      <RunLog id={run.id} live={live} />
                    </Table.Td>
                  </Table.Tr>
                ) : null,
              ])}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
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
