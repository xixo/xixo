import { Button, Group, Loader, Modal, Text } from '@mantine/core'
import { useState } from 'react'
import {
  CancelRunDocument,
  RunLogDocument,
  RunProgressedDocument,
  RunsDocument,
  type RunsQuery,
} from 'xixo'
import { useQuery, useSubscription } from 'xixo/react'
import { usePages } from '../hooks/usePages'
import { toned } from '../looks'
import { RUN_OPEN, RUN_TONES, TONE_FOR_LINE } from '../runs'
import { ago } from '../when'
import { Failed } from './Failed'
import { useAloud, useSay } from './Say'

const PAGE = 20

type Run = RunsQuery['runs']['nodes'][number]

const KINDS: Record<string, string> = {
  sync: 'Sync',
  export: 'Export',
  reindex: 'Reindex',
}

function lasted(run: Run) {
  if (!run.startedAt) return null

  const end = run.finishedAt ? Date.parse(run.finishedAt) : Date.now()
  const seconds = Math.max(
    0,
    Math.round((end - Date.parse(run.startedAt)) / 1000),
  )

  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`

  return `${(seconds / 3600).toFixed(1)} h`
}

export function RunsDialog({
  resource,
  onClose,
}: {
  resource: { id: string; key: string }
  onClose: () => void
}) {
  return (
    <Modal
      opened
      onClose={onClose}
      title={`What ${resource.key} has done`}
      size="lg"
      radius="md"
    >
      <Runs resourceId={resource.id} />
    </Modal>
  )
}

export function Runs({ resourceId }: { resourceId: string }) {
  const say = useSay()
  const [cursor, setCursor] = useState<string | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  const { data, loading, error, refetch } = useQuery(RunsDocument, {
    resourceId,
    after: cursor,
    limit: PAGE,
  })
  const { data: progressed } = useSubscription(RunProgressedDocument, {})
  const cancel = useAloud(CancelRunDocument, 'That run could not be cancelled.')
  const page = data?.runs
  const [runs] = usePages<Run>(page, cursor)
  const streamed = progressed?.runProgressed.run
  const next = page?.hasMore ? (page.nextCursor ?? null) : null

  if (error) return <Failed error={error} retry={refetch} />
  if (loading && runs.length === 0)
    return <Loader size="sm" color="var(--accent)" />

  if (runs.length === 0) {
    return (
      <Text size="sm" c="dimmed">
        Nothing has run here yet. A sync, an export, or a reindex shows up here
        with what it did.
      </Text>
    )
  }

  return (
    <div className="panel passes">
      {runs.map((held) => {
        const run = streamed?.id === held.id ? { ...held, ...streamed } : held
        const shown = open === run.id
        const running = RUN_OPEN.has(run.status)

        return (
          <div key={run.id} className="pass" data-open={shown}>
            <button
              type="button"
              className="pass-head"
              aria-expanded={shown}
              onClick={() => setOpen(shown ? null : run.id)}
            >
              <span
                className="tag"
                style={toned(RUN_TONES[run.status] ?? 'var(--edge)')}
              >
                {run.status}
              </span>
              <span className="pass-cause">{KINDS[run.kind] ?? run.kind}</span>
              <span className="pass-when">{ago(run.createdAt)}</span>
              <span className="pass-steps figure">
                {run.processed.toLocaleString()}{' '}
                {run.processed === 1 ? 'item' : 'items'}
                {lasted(run) ? ` · ${lasted(run)}` : ''}
              </span>
            </button>

            {run.error && <div className="pass-error">{run.error}</div>}

            {shown && (
              <div className="pass-body">
                {running && (
                  <Group>
                    <Button
                      size="compact-sm"
                      radius="xl"
                      variant="default"
                      color="red"
                      loading={cancel.loading}
                      onClick={async () => {
                        const answered = await cancel.execute({ id: run.id })

                        if (answered?.cancelRun?.cancelled)
                          say({ text: 'The run is cancelled.' })
                      }}
                    >
                      Cancel this run
                    </Button>
                  </Group>
                )}
                <Log
                  id={run.id}
                  live={
                    streamed?.id === run.id ? (streamed.logs ?? null) : null
                  }
                />
              </div>
            )}
          </div>
        )
      })}

      {next !== null && (
        <Group justify="center" p="var(--s2)">
          <Button
            size="compact-sm"
            radius="xl"
            variant="subtle"
            onClick={() => setCursor(next)}
          >
            Show older runs
          </Button>
        </Group>
      )}
    </div>
  )
}

function Log({ id, live }: { id: string; live: string | null }) {
  const { data, loading } = useQuery(RunLogDocument, { id })
  const lines = (live ?? data?.run?.logs ?? '').split('\n').filter(Boolean)

  if (loading && !data) return <Loader size="xs" color="var(--accent)" />
  if (lines.length === 0) {
    return (
      <Text size="sm" c="dimmed">
        This run wrote nothing to its log.
      </Text>
    )
  }

  return (
    <div className="run-log">
      {lines.map((line, index) => (
        <div
          // biome-ignore lint/suspicious/noArrayIndexKey: position is the identity
          key={index}
          style={{ color: TONE_FOR_LINE[line.slice(0, 3)] ?? 'var(--soft)' }}
        >
          {line}
        </div>
      ))}
    </div>
  )
}
