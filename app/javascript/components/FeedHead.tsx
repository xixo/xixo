import { Button, Group, Menu, Text } from '@mantine/core'
import {
  IconDots,
  IconPencil,
  IconPlayerPause,
  IconPlayerPlay,
  IconTrash,
} from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  AnalysisProgressedDocument,
  CancelAnalysisDocument,
  DeleteFeedDocument,
  PauseFeedDocument,
  RunFeedDocument,
} from 'xixo'
import { useSubscription } from 'xixo/react'
import { toned } from '../looks'
import { RUN_OPEN } from '../runs'
import { type Feed as Editable, EVERY, FeedForm } from './FeedForm'
import { useAloud, useSay } from './Say'
import { Sure } from './Sure'

export interface Pass {
  id: string
  cause: string
  status: string
  error?: string | null
  said?: string | null
  turns?: unknown
  createdAt: string
  finishedAt?: string | null
}

interface Feed extends Editable {
  schedule?:
    | (Editable['schedule'] & {
        pausedAt?: string | null
        nextRunAt?: string | null
      })
    | null
}

interface Turn {
  turn: number
  calls: string[]
  said?: string | null
}

interface Stored {
  n?: number
  role?: string
  calls?: string[]
  content?: string | null
}

function agentTurns(turns: unknown): Turn[] {
  if (!Array.isArray(turns)) return []

  return (turns as Stored[])
    .filter((held) => held.role === 'agent')
    .map((held) => ({
      turn: Number(held.n ?? 0),
      calls: held.calls ?? [],
      said: held.content,
    }))
}

function when(value?: string | null) {
  return value ? new Date(value).toLocaleString() : null
}

function cadence(feed: Feed) {
  const schedule = feed.schedule

  if (!schedule?.interval) return 'Runs when you run it'

  const named = EVERY.find(
    (every) => every.seconds === schedule.interval,
  )?.label
  const every = named ?? `every ${Math.round(schedule.interval / 60)} minutes`

  if (schedule.pausedAt) return `Runs ${every} — paused`

  const next = when(schedule.nextRunAt)

  return next ? `Runs ${every} · next ${next}` : `Runs ${every}`
}

export function FeedHead({
  feed,
  passes,
  onChanged,
}: {
  feed: Feed
  passes: readonly Pass[]
  onChanged: () => void
}) {
  const say = useSay()
  const navigate = useNavigate()
  const [editing, setEditing] = useState(false)
  const [deleting, setDeleting] = useState(false)

  const start = useAloud(RunFeedDocument, 'That feed could not be run.')
  const pause = useAloud(PauseFeedDocument, 'That feed could not be paused.')
  const remove = useAloud(DeleteFeedDocument, 'That feed could not be deleted.')

  const open = passes.find((pass) => RUN_OPEN.has(pass.status))
  const last = passes.find((pass) => !RUN_OPEN.has(pass.status))

  return (
    <section className="feed-head">
      <div className="feed-head-top">
        <div style={{ minWidth: 0 }}>
          <h1 className="page-title mono-title">{feed.key}</h1>
          {feed.title && <div className="feed-head-name">{feed.title}</div>}
        </div>

        <Group gap="var(--s2)" wrap="nowrap">
          <Button
            radius="xl"
            color="brand"
            leftSection={<IconPlayerPlay size={15} />}
            loading={start.loading}
            disabled={Boolean(open)}
            onClick={async () => {
              const answered = await start.execute({ id: feed.id })

              if (!answered) return

              say({ text: `${feed.key} is queued to run.` })
              onChanged()
            }}
          >
            {open
              ? open.status === 'queued'
                ? 'Queued'
                : 'Running'
              : 'Run now'}
          </Button>

          <Button
            radius="xl"
            variant="default"
            leftSection={<IconPencil size={15} />}
            onClick={() => setEditing(true)}
          >
            Edit
          </Button>

          <Menu position="bottom-end" width={200}>
            <Menu.Target>
              <Button
                radius="xl"
                variant="subtle"
                color="gray"
                aria-label={`More for ${feed.key}`}
              >
                <IconDots size={16} stroke={1.8} />
              </Button>
            </Menu.Target>
            <Menu.Dropdown>
              {feed.schedule?.interval ? (
                <Menu.Item
                  leftSection={
                    feed.schedule.pausedAt ? (
                      <IconPlayerPlay size={15} stroke={1.6} />
                    ) : (
                      <IconPlayerPause size={15} stroke={1.6} />
                    )
                  }
                  onClick={async () => {
                    const answered = await pause.execute({
                      id: feed.id,
                      paused: !feed.schedule?.pausedAt,
                    })

                    if (!answered) return

                    say({
                      text: feed.schedule?.pausedAt
                        ? `${feed.key} runs on its own again.`
                        : `${feed.key} is paused. It will only run by hand.`,
                    })
                    onChanged()
                  }}
                >
                  {feed.schedule.pausedAt
                    ? 'Resume the schedule'
                    : 'Pause the schedule'}
                </Menu.Item>
              ) : null}

              <Menu.Item
                color="red"
                leftSection={<IconTrash size={15} stroke={1.6} />}
                onClick={() => setDeleting(true)}
              >
                Delete
              </Menu.Item>
            </Menu.Dropdown>
          </Menu>
        </Group>
      </div>

      {feed.schedule?.prompt && (
        <p className="feed-head-prompt">{feed.schedule.prompt}</p>
      )}

      <div className="eyebrow">{cadence(feed)}</div>

      {open ? (
        <Progress key={open.id} pass={open} />
      ) : last ? (
        <LastRun pass={last} />
      ) : null}

      <FeedForm
        opened={editing}
        onClose={() => setEditing(false)}
        feed={feed}
        onSaved={(saved) => {
          say({ text: `${saved} is saved.` })
          onChanged()
          navigate(saved)
        }}
      />

      <Sure
        opened={deleting}
        onClose={() => setDeleting(false)}
        title={`Delete ${feed.key}?`}
        verb="Delete it"
        loading={remove.loading}
        onSure={async () => {
          const answered = await remove.execute({ id: feed.id })

          if (!answered) return

          const kept = answered.deleteFeed?.kept ?? 0

          setDeleting(false)
          say({
            text: kept
              ? `${feed.key} is gone. The ${kept} ${kept === 1 ? 'item' : 'items'} it wrote stayed in your catalog.`
              : `${feed.key} is gone.`,
          })
          onChanged()
          navigate('/')
        }}
      >
        The prompt and its run history go. Anything it wrote stays in your
        catalog as an ordinary item — deleting the feed that found something is
        not the same as throwing the something away.
      </Sure>
    </section>
  )
}

function LastRun({ pass }: { pass: Pass }) {
  const failed = pass.status !== 'done'

  return (
    <div
      className="run-card"
      style={toned(failed ? 'var(--bad)' : 'var(--ok)')}
    >
      <div className="run-card-head">
        <span className="tag">{pass.status}</span>
        <span className="eyebrow">
          last run {when(pass.finishedAt ?? pass.createdAt)}
        </span>
      </div>
      <Text size="sm" className="run-card-said">
        {pass.error ?? pass.said ?? 'It finished without saying anything.'}
      </Text>
    </div>
  )
}

const NOISE = /^(\[.{1,2}\]\s*:\s*|called [^\n]*\n+|thinking:\s*)+/i

function tidy(text?: string | null) {
  return (text ?? '').replace(NOISE, '').replace(/\s+/g, ' ').trim()
}

function glimpse(turns: Turn[], logs?: string | null) {
  for (let at = turns.length - 1; at >= 0; at -= 1) {
    const said = tidy(turns[at].said)

    if (said) return said
  }

  return tidy((logs ?? '').split('\n').filter(Boolean).pop()) || null
}

export function Progress({ pass }: { pass: Pass }) {
  const [turns, setTurns] = useState<Turn[]>(agentTurns(pass.turns))
  const { data } = useSubscription(AnalysisProgressedDocument, { id: pass.id })
  const streamed = data?.analysisProgressed.analysis
  const status = streamed?.status ?? pass.status

  useEffect(() => {
    if (Array.isArray(streamed?.turns)) setTurns(agentTurns(streamed.turns))
  }, [streamed])

  const cancel = useAloud(
    CancelAnalysisDocument,
    'That run could not be stopped.',
  )
  const say = useSay()
  const [stopped, setStopped] = useState(false)

  const stop = async () => {
    const answered = await cancel.execute({ id: pass.id })

    if (!answered) return

    if (!answered.cancelAnalysis?.cancelled) {
      say({ text: 'That run had already finished.' })
      return
    }

    setStopped(true)
    say({ text: 'The run was stopped.' })
  }

  const stopper = (
    <Button
      size="compact-xs"
      variant="subtle"
      color="red"
      loading={cancel.loading}
      onClick={stop}
    >
      Stop
    </Button>
  )

  if (stopped || status === 'cancelled') return null

  if (status === 'queued') {
    return (
      <div
        className="run-card"
        data-waiting="true"
        style={toned('var(--edge)')}
      >
        <div className="run-card-head">
          <span className="tag">queued</span>
          <span className="eyebrow">asked {when(pass.createdAt)}</span>
          {stopper}
        </div>
        <Text size="sm" className="run-card-said">
          Waiting for a worker. A run you ask for goes ahead of files still
          being synced, but not ahead of a pass already under way.
        </Text>
      </div>
    )
  }

  const line = glimpse(turns, streamed?.logs) ?? 'Reading the catalog'

  return (
    <div className="thinking" aria-live="polite">
      <span className="thinking-pulse" />
      <span className="label">Thinking</span>
      <span className="thinking-line" key={line}>
        {line}
      </span>
      {stopper}
    </div>
  )
}
