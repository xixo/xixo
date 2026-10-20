import { Group, Menu } from '@mantine/core'
import { IconChevronDown, IconX } from '@tabler/icons-react'
import { type ReactNode, useMemo } from 'react'
import { useSearchParams } from 'react-router-dom'
import { PlacesDocument, SliceCountsDocument } from 'xixo'
import { useQuery } from 'xixo/react'
import { toned, toneOf } from '../looks'

export const SLICE_PARAMS = [
  'machine',
  'resource',
  'analysis',
  'kind',
  'added',
] as const

const SPANS: Record<string, { label: string; ms: number }> = {
  day: { label: 'Past day', ms: 86_400_000 },
  week: { label: 'Past week', ms: 7 * 86_400_000 },
  month: { label: 'Past month', ms: 30 * 86_400_000 },
  year: { label: 'Past year', ms: 365 * 86_400_000 },
}

const STATES: Record<string, string> = {
  analyzed: 'Analyzed',
  waiting: 'Waiting for analysis',
  parked: 'Waiting for a machine or a model server',
  failed: 'Failed',
}

const KINDS: Record<string, string> = {
  pdf: 'PDFs',
  email: 'email',
  calendar: 'calendars',
  contact: 'contacts',
  pkpass: 'passes',
  page: 'pages',
  xlsx: 'spreadsheets',
  doc: 'documents',
  data: 'data files',
  image: 'images',
  video: 'video',
  audio: 'audio',
  text: 'text',
  file: 'other files',
}

export function sliceKey(params: URLSearchParams) {
  return SLICE_PARAMS.map((name) => params.get(name) ?? '').join(' ')
}

export interface Slice {
  machineId: string | null
  resourceId: string | null
  analysis: string | null
  kind: string | null
  since: string | null
}

export function useSlice(): { slice: Slice; set: boolean } {
  const [params] = useSearchParams()
  const key = sliceKey(params)

  return useMemo(() => {
    const [machine, resource, analysis, kind, added] = key.split(' ')
    const span = SPANS[added]
    const slice: Slice = {
      machineId: resource ? null : machine || null,
      resourceId: resource || null,
      analysis: analysis in STATES ? analysis : null,
      kind: kind in KINDS ? kind : null,
      since: span ? new Date(Date.now() - span.ms).toISOString() : null,
    }
    const set = Object.values(slice).some((value) => value !== null)

    return { slice, set }
  }, [key])
}

interface Counted {
  key: string
  count: number
}

function tally(counts: readonly Counted[] | undefined) {
  return new Map((counts ?? []).map((held) => [held.key, held.count]))
}

export function Filters({
  query,
  types,
  connectedTo,
  topLevel,
}: {
  query: string | null
  types: string[] | null
  connectedTo: string | null
  topLevel: boolean
}) {
  const [params, setParams] = useSearchParams()
  const { slice } = useSlice()
  const places = useQuery(PlacesDocument)
  const counts = useQuery(SliceCountsDocument, {
    query,
    types,
    connectedTo,
    topLevel,
    ...slice,
  })

  const change = (next: Record<string, string | null>) => {
    const held = new URLSearchParams(params)

    for (const [name, value] of Object.entries(next)) {
      if (value) held.set(name, value)
      else held.delete(name)
    }

    setParams(held)
  }

  const found = counts.data?.sliceCounts
  const where = tally(found?.where)
  const analysis = tally(found?.analysis)
  const kinds = tally(found?.kind)
  const spans = tally(found?.when)

  const resources = places.data?.resources ?? []
  const machines = resources.filter((held) => held.type === 'machine')
  const named = (id: string | null) =>
    resources.find((held) => held.id === id)?.name ??
    resources.find((held) => held.id === id)?.key ??
    null
  const holding = (machine: string) =>
    resources.filter(
      (held) => held.type !== 'machine' && held.machineId === machine,
    )
  const elsewhere = resources.filter(
    (held) =>
      held.type !== 'machine' &&
      !machines.some((machine) => machine.id === held.machineId),
  )
  const onMachine = (machine: string) =>
    holding(machine).reduce((sum, held) => sum + (where.get(held.id) ?? 0), 0)

  const machine = params.get('machine')
  const resource = params.get('resource')
  const state = params.get('analysis')
  const kind = params.get('kind')
  const added = params.get('added')

  const placed = resource ? named(resource) : machine ? named(machine) : null

  const folder = (held: { id: string; name?: string | null; key: string }) => (
    <Item
      key={held.id}
      label={held.name ?? held.key}
      count={where.get(held.id) ?? 0}
      on={resource === held.id}
      indented
      onClick={() => change({ resource: held.id, machine: null })}
    />
  )

  return (
    <div className="shelf filters" role="toolbar" aria-label="Filters">
      <Filter
        name="Where"
        shown={placed}
        onClear={() => change({ machine: null, resource: null })}
      >
        {machines.map((held) => (
          <div key={held.id}>
            <Item
              label={held.name ?? held.key}
              count={onMachine(held.id)}
              on={machine === held.id && !resource}
              onClick={() => change({ machine: held.id, resource: null })}
            />
            {holding(held.id).map(folder)}
          </div>
        ))}
        {elsewhere.length > 0 && machines.length > 0 && <Menu.Divider />}
        {elsewhere.map(folder)}
      </Filter>

      <Filter
        name="Analysis"
        shown={state && STATES[state] ? STATES[state] : null}
        onClear={() => change({ analysis: null })}
      >
        {Object.entries(STATES).map(([key, label]) => (
          <Item
            key={key}
            label={label}
            count={analysis.get(key) ?? 0}
            on={state === key}
            onClick={() => change({ analysis: key })}
          />
        ))}
      </Filter>

      <Filter
        name="Kind"
        shown={kind && KINDS[kind] ? KINDS[kind] : null}
        tone={kind ? toneOf(kind) : undefined}
        onClear={() => change({ kind: null })}
      >
        {Object.entries(KINDS)
          .filter(([key]) => (kinds.get(key) ?? 0) > 0 || kind === key)
          .map(([key, label]) => (
            <Item
              key={key}
              label={label}
              count={kinds.get(key) ?? 0}
              on={kind === key}
              tone={toneOf(key)}
              onClick={() => change({ kind: key })}
            />
          ))}
      </Filter>

      <Filter
        name="When"
        shown={added && SPANS[added] ? SPANS[added].label : null}
        onClear={() => change({ added: null })}
      >
        {Object.entries(SPANS).map(([key, span]) => (
          <Item
            key={key}
            label={`Added in the ${span.label.toLowerCase()}`}
            count={spans.get(key) ?? 0}
            on={added === key}
            onClick={() => change({ added: key })}
          />
        ))}
      </Filter>
    </div>
  )
}

function Filter({
  name,
  shown,
  tone,
  onClear,
  children,
}: {
  name: string
  shown: string | null
  tone?: string
  onClear: () => void
  children: ReactNode
}) {
  return (
    <span className="filter" data-on={shown !== null}>
      <Menu position="bottom-start" width={280}>
        <Menu.Target>
          <button
            type="button"
            className="chip"
            data-on={shown !== null}
            aria-label={shown ? `${name}: ${shown}` : name}
          >
            {tone && <span className="dot" style={toned(tone)} />}
            {shown ?? name}
            {shown === null && (
              <IconChevronDown className="filter-mark" size={14} stroke={1.8} />
            )}
          </button>
        </Menu.Target>
        <Menu.Dropdown mah={360} style={{ overflowY: 'auto' }}>
          {children}
        </Menu.Dropdown>
      </Menu>
      {shown !== null && (
        <button
          type="button"
          className="filter-clear"
          aria-label={`Clear ${name.toLowerCase()}`}
          onClick={onClear}
        >
          <IconX size={12} stroke={2.2} />
        </button>
      )}
    </span>
  )
}

function Item({
  label,
  count,
  on,
  tone,
  indented,
  onClick,
}: {
  label: string
  count: number
  on: boolean
  tone?: string
  indented?: boolean
  onClick: () => void
}) {
  return (
    <Menu.Item
      onClick={onClick}
      aria-current={on || undefined}
      fw={on ? 600 : undefined}
      pl={indented ? 'var(--s6)' : undefined}
      leftSection={
        tone ? <span className="dot" style={toned(tone)} /> : undefined
      }
    >
      <Group justify="space-between" gap="var(--s4)" wrap="nowrap">
        <span>{label}</span>
        <span className="figure">{count.toLocaleString()}</span>
      </Group>
    </Menu.Item>
  )
}
