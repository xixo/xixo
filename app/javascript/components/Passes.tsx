import { Loader, Text } from '@mantine/core'
import { useEffect, useRef, useState } from 'react'
import {
  AnalysisLogDocument,
  AnalysisProgressedDocument,
  type PassFragment,
} from 'xixo'
import { useQuery, useSubscription } from 'xixo/react'
import { toned } from '../looks'
import { RUN_OPEN, RUN_TONES, TONE_FOR_LINE } from '../runs'

const CAUSES: Record<string, string> = {
  upload: 'uploaded',
  sync: 'synced',
  keep: 'kept',
  edge: 'connected',
  schedule: 'on schedule',
  manual: 'asked for',
}

interface Step {
  started_at?: string
  finished_at?: string
  result?: unknown
  error?: { class?: string; message?: string }
}

export interface Placement {
  resource: string
  path: string
  by: 'agent' | 'return' | 'default'
  reason: string
}

export function placementOf(passes: readonly PassFragment[]): Placement | null {
  for (const pass of passes) {
    const step = (pass.steps as Record<string, Step>).placement

    if (step?.result) return step.result as Placement
  }

  return null
}

function when(value?: string | null) {
  return value ? new Date(value).toLocaleString() : '—'
}

function lasted(ms?: number | null) {
  if (ms == null) return null
  if (ms < 1000) return `${ms}ms`

  return `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)}s`
}

function took(step: Step) {
  if (!step.started_at || !step.finished_at) return null

  return lasted(Date.parse(step.finished_at) - Date.parse(step.started_at))
}

export function Passes({
  passes,
  onSettled,
}: {
  passes: readonly PassFragment[]
  onSettled: () => void
}) {
  const [open, setOpen] = useState<string | null>(null)
  const { data } = useSubscription(AnalysisProgressedDocument, {})
  const streamed = data?.analysisProgressed.analysis
  const answered = useRef<string | null>(null)

  useEffect(() => {
    if (!streamed || !passes.some((pass) => pass.id === streamed.id)) return

    const reached = `${streamed.id} ${streamed.status}`

    if (answered.current === reached) return

    answered.current = reached
    if (!RUN_OPEN.has(streamed.status)) onSettled()
  }, [streamed, passes, onSettled])

  if (passes.length === 0) {
    return (
      <Text c="dimmed" size="sm">
        Nothing has looked at this yet.
      </Text>
    )
  }

  return (
    <div className="panel passes">
      {passes.map((pass) => {
        const live = streamed?.id === pass.id ? streamed : null
        const status = live?.status ?? pass.status
        const steps = Object.entries(
          (live?.steps ?? pass.steps) as Record<string, Step>,
        )
        const shown = open === pass.id

        return (
          <div key={pass.id} className="pass" data-open={shown}>
            <button
              type="button"
              className="pass-head"
              aria-expanded={shown}
              onClick={() => setOpen(shown ? null : pass.id)}
            >
              <span
                className="tag"
                style={toned(RUN_TONES[status] ?? 'var(--edge)')}
              >
                {status}
              </span>
              <span className="pass-cause">
                {CAUSES[pass.cause] ?? pass.cause}
              </span>
              <span className="pass-when">{when(pass.createdAt)}</span>
              <span className="pass-steps figure">
                {steps.length} {steps.length === 1 ? 'step' : 'steps'}
                {lasted(live?.durationMs ?? pass.durationMs)
                  ? ` · ${lasted(live?.durationMs ?? pass.durationMs)}`
                  : ''}
              </span>
            </button>

            {(live?.error ?? pass.error) && (
              <div className="pass-error">{live?.error ?? pass.error}</div>
            )}

            {shown && (
              <div className="pass-body">
                {steps.length > 0 && (
                  <div className="pass-grid">
                    {steps.map(([name, step]) => (
                      <div
                        key={name}
                        className="pass-step"
                        data-failed={Boolean(step.error)}
                      >
                        <span className="pass-name mono">{name}</span>
                        <span className="pass-took figure">{took(step)}</span>
                        <span className="pass-said">
                          {step.error
                            ? step.error.message
                            : name === 'placement'
                              ? `${(step.result as Placement).resource}/${(step.result as Placement).path}. ${why(step.result as Placement)}`
                              : null}
                        </span>
                      </div>
                    ))}
                  </div>
                )}

                <Log id={pass.id} live={live?.logs ?? null} />
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

export function why(placement: Placement) {
  if (placement.by === 'agent')
    return `Chosen by the agent — ${placement.reason}`
  if (placement.by === 'return')
    return 'Put back where it was, over the file already there'

  return `Nobody chose, so it went to ${placement.reason}`
}

function Log({ id, live }: { id: string; live: string | null }) {
  const { data, loading } = useQuery(AnalysisLogDocument, { id })
  const logs = live ?? data?.analysis?.logs ?? ''
  const lines = logs.split('\n').filter(Boolean)

  if (loading && !data) return <Loader size="xs" color="var(--accent)" />
  if (lines.length === 0) return null

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
