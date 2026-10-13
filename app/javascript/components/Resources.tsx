import {
  ActionIcon,
  Alert,
  Button,
  Loader,
  Menu,
  NumberInput,
  Popover,
  SegmentedControl,
  Switch,
} from '@mantine/core'
import {
  IconArchive,
  IconArchiveOff,
  IconCheck,
  IconChevronDown,
  IconClock,
  IconCpu,
  IconDots,
  IconHistory,
  IconLock,
  IconPencil,
  IconPlugConnected,
  IconPlus,
  IconRefresh,
  IconServer,
  IconShieldLock,
  IconSparkles,
  IconStar,
  IconTrash,
} from '@tabler/icons-react'
import {
  type CSSProperties,
  type ReactNode,
  type RefObject,
  useEffect,
  useRef,
  useState,
} from 'react'
import { useParams, useSearchParams } from 'react-router-dom'
import {
  ArchiveResourceDocument,
  CheckResourceDocument,
  DeleteResourceDocument,
  ResourcesDocument,
  SetDefaultInferenceDocument,
  SetDefaultStorageDocument,
  SetMachineAccessDocument,
  SetSyncIntervalDocument,
  SyncResourceDocument,
  UnlinkedMachinesDocument,
} from 'xixo'
import { useQuery } from 'xixo/react'
import { session } from '../hooks/useSession'
import { useTitle } from '../hooks/useTitle'
import {
  cannotRead,
  disks,
  does,
  humane,
  lastSeen,
  memory,
  reads,
  upFor,
  type Waiting,
  waitingForAny,
  waitingOn,
  warning,
} from '../plain'
import { unraised } from '../shared'
import { ago, dated } from '../when'
import {
  AddTo,
  addedAs,
  type Form,
  type Place,
  quickFor,
  SERVERS,
  useQuickAdd,
} from './AddTo'
import { Attach, type Editing, glyphFor } from './Attach'
import { Failed } from './Failed'
import {
  AskingLine,
  LinkUpDialog,
  type LinkUpInfo,
  LinkUpTile,
  useLinkRequests,
} from './LinkUp'
import { MachineIcon } from './MachineIcon'
import { LinkMark } from './Mark'
import { RunsDialog } from './Runs'
import { useAloud, useSay } from './Say'
import { Intro } from './Settings'
import { Sure } from './Sure'

interface Resource {
  id: string
  type: string
  key: string
  name?: string | null
  healthy: boolean
  checking: boolean
  checkedAt?: string | null
  checkError?: string | null
  offline: boolean
  offlineHost?: string | null
  offlineLastSeenAt?: string | null
  emptiedAt?: string | null
  syncing: boolean
  syncable: boolean
  defaultStorage: boolean
  defaultInference: boolean
  itemsCount: number
  capabilities: string[]
  syncInterval?: number | null
  syncedAt?: string | null
  nextSyncAt?: string | null
  archivedAt?: string | null
  settings: Record<string, unknown>
  heldCredentials: string[]
  changeable: boolean
  manageable: boolean
  personal: boolean
  delegated: boolean
  needsConnect: boolean
  connectedBy?: string | null
  connectUrl?: string | null
  via?: string | null
  machineId?: string | null
  machine?: {
    hostname?: string | null
    version?: string | null
    connected: boolean
    seenAt?: string | null
    uptime?: number | null
    folders: string[]
    extractors: string[]
    unread: string[]
    access: string
    helpsOthers: boolean
    heldBack: string[]
    lends: boolean
    tools: string[]
    warnings: string[]
    os?: string | null
    system?: string | null
    model?: string | null
    kind?: string | null
    arch?: string | null
    extractsForOthers: boolean
    waiting: Waiting[]
    linked: boolean
    services: {
      kind: string
      port: number
      address?: string | null
      localOnly?: boolean
      url?: string | null
      via?: string | null
    }[]
    memoryTotal?: number | string | null
    memoryAvailable?: number | string | null
    disks: {
      path: string
      total?: number | string | null
      free?: number | string | null
    }[]
  } | null
}

interface Group {
  machine: Resource | null
  place: Place
  rows: Resource[]
}

const MACHINE = 'machine'
const LOCAL = 'local'
const THIS_SERVER = 'This server'

const CHECKING_POLL = 2000

const SYSTEMS: Record<string, string> = {
  darwin: 'macOS',
  linux: 'Linux',
  windows: 'Windows',
}

interface Status {
  tone: string
  said: string | null
  busy: boolean
  wrong: boolean
}

function status(resource: Resource): Status {
  const machine = resource.machine

  if (resource.syncing)
    return { tone: 'var(--busy)', said: 'syncing', busy: true, wrong: false }
  if (resource.needsConnect)
    return {
      tone: 'var(--bad)',
      said: resource.connectedBy ? 'needs reconnecting' : 'not connected',
      busy: false,
      wrong: true,
    }
  if (resource.checking)
    return { tone: 'var(--busy)', said: 'checking', busy: true, wrong: false }
  if (machine && !machine.linked && resource.key !== LOCAL)
    return {
      tone: 'var(--edge)',
      said: 'not linked',
      busy: false,
      wrong: false,
    }
  if (machine)
    return machine.connected
      ? { tone: 'var(--ok)', said: 'online', busy: false, wrong: false }
      : {
          tone: 'var(--away)',
          said: ['offline', lastSeen(machine)].filter(Boolean).join(' · '),
          busy: false,
          wrong: false,
        }
  if (resource.offline)
    return {
      tone: 'var(--away)',
      said: resource.offlineLastSeenAt
        ? `offline · last seen ${ago(resource.offlineLastSeenAt)}`
        : 'offline',
      busy: false,
      wrong: false,
    }
  if (resource.checkedAt && !resource.healthy)
    return { tone: 'var(--bad)', said: 'not working', busy: false, wrong: true }

  return { tone: 'var(--ok)', said: null, busy: false, wrong: false }
}

function told(resource: Resource) {
  if (resource.offline) {
    const host = resource.offlineHost ?? 'its machine'

    return resource.offlineLastSeenAt
      ? `${host} was last seen ${ago(resource.offlineLastSeenAt)}`
      : `${host} has not been seen on ${resource.via ?? 'its network'}`
  }

  if (resource.checkError) return humane(resource.checkError)

  return resource.checkedAt
    ? `checked ${ago(resource.checkedAt)}`
    : 'not checked yet'
}

function plural(count: number, one: string, many = `${one}s`) {
  return `${count.toLocaleString()} ${count === 1 ? one : many}`
}

function named(resource: Resource) {
  return resource.name || resource.key
}

function system(machine: Resource) {
  if (machine.key === LOCAL) return does(machine)

  const held = machine.machine
  const os = held?.os ? (SYSTEMS[held.os] ?? held.os) : null

  return (
    [held?.hostname !== machine.key ? held?.hostname : null, os, held?.arch]
      .filter(Boolean)
      .join(' · ') || does(machine)
  )
}

function facts(machine: NonNullable<Resource['machine']>, place: Place) {
  if (!machine.linked && !machine.connected && !machine.seenAt) return []

  const shared = place.folders.length

  return [
    shared === 0
      ? 'Shares no folders yet'
      : `Shares ${plural(shared, 'folder')}`,
    reads(machine.extractors, machine.unread),
    heldBack(machine.heldBack),
    waitingOn(machine.waiting, machine.connected),
  ].filter((line): line is string => Boolean(line))
}

const HELD_BACK: Record<string, string> = {
  lend: 'whole files',
  extracts_for_others: "reading other machines' files",
}

function heldBack(held: string[]) {
  if (held.length === 0) return null

  return `Its own config holds back ${held.map((name) => HELD_BACK[name] ?? name).join(', ')}`
}

function placeOf(machine: Resource | null): Place {
  if (!machine)
    return {
      id: null,
      key: LOCAL,
      name: THIS_SERVER,
      host: 'localhost',
      local: true,
      folders: [],
      services: [],
    }

  return {
    id: machine.id,
    key: machine.key,
    name: machine.key === LOCAL ? THIS_SERVER : named(machine),
    host: machine.machine?.hostname || machine.key,
    local: machine.key === LOCAL,
    folders: machine.machine?.folders ?? [],
    services: machine.machine?.services ?? [],
  }
}

function grouped(resources: Resource[]): Group[] {
  const machines = resources
    .filter((resource) => resource.type === MACHINE)
    .sort(
      (a, b) =>
        Number(b.key === LOCAL) - Number(a.key === LOCAL) ||
        Number(Boolean(b.machine?.connected)) -
          Number(Boolean(a.machine?.connected)) ||
        a.key.localeCompare(b.key),
    )
  const local = machines.find((machine) => machine.key === LOCAL) ?? null
  const known = new Set(machines.map((machine) => machine.id))
  const others = resources.filter((resource) => resource.type !== MACHINE)
  const homeless = others.filter(
    (resource) => !resource.machineId || !known.has(resource.machineId),
  )
  const groups = machines.map((machine) => ({
    machine,
    place: placeOf(machine),
    rows: others.filter((resource) => resource.machineId === machine.id),
  }))

  if (local) {
    groups[0].rows.push(...homeless)
    return groups
  }

  return [{ machine: null, place: placeOf(null), rows: homeless }, ...groups]
}

function placed(rows: Resource[]) {
  const rank = (resource: Resource) =>
    resource.capabilities.includes('storage')
      ? 0
      : resource.capabilities.includes('inference')
        ? 1
        : resource.capabilities.includes('transport')
          ? 3
          : 2

  return [...rows].sort(
    (a, b) => rank(a) - rank(b) || a.key.localeCompare(b.key),
  )
}

export function Resources() {
  useTitle('Resources')

  const { id: landed } = useParams()
  const [connectError, setConnectError] = useState(() =>
    new URLSearchParams(window.location.search).get('connect_error'),
  )
  const say = useSay()
  const [shelved, setShelved] = useState(false)
  const { data, loading, error, refetch } = useQuery(ResourcesDocument, {
    archived: shelved,
  })
  const sync = useAloud(SyncResourceDocument, 'That resource could not sync.')
  const check = useAloud(
    CheckResourceDocument,
    'That resource could not be checked.',
  )
  const takeDrops = useAloud(
    SetDefaultStorageDocument,
    'That could not take drops.',
  )
  const takeQuestions = useAloud(
    SetDefaultInferenceDocument,
    'That could not take questions.',
  )
  const setInterval = useAloud(
    SetSyncIntervalDocument,
    'That schedule could not be set.',
  )
  const archive = useAloud(
    ArchiveResourceDocument,
    'That resource could not be put away.',
  )

  const [putting, setPutting] = useState<string | null>(null)
  const remove = useAloud(
    DeleteResourceDocument,
    'That resource could not be deleted.',
  )
  const [deleting, setDeleting] = useState<Resource | null>(null)

  const deleteIt = async (resource: Resource) => {
    const answered = await remove.execute({ id: resource.id })

    if (!answered) return

    const places = answered.deleteResource?.places ?? 0

    setDeleting(null)
    say({
      text: `${resource.key} is deleted. xixo stopped pointing at ${places} ${places === 1 ? 'place' : 'places'} in it.`,
    })
    refetch()
  }

  const putAway = async (resource: Resource, archived: boolean) => {
    setPutting(resource.id)

    const answered = await archive
      .execute({ id: resource.id, archived })
      .finally(() => setPutting(null))

    if (!answered) return

    say({
      text: archived
        ? `${resource.key} is put away. What it catalogued stays where it is.`
        : `${resource.key} is back in use.`,
    })
    refetch()
  }
  const [params, setParams] = useSearchParams()
  const [adding, setAdding] = useState<{
    place: string
    choosing: boolean
  } | null>(params.has('attach') ? { place: LOCAL, choosing: true } : null)
  const [form, setForm] = useState<Form | null>(null)
  const [editing, setEditing] = useState<Editing | null>(null)
  const [linkingUp, setLinkingUp] = useState(false)
  const [history, setHistory] = useState<Resource | null>(null)
  const arrived = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (landed) arrived.current?.scrollIntoView({ block: 'center' })
  }, [landed])

  const checking = (data?.resources ?? []).some((resource) => resource.checking)
  const administering = data?.administrator ?? false
  const asking = useLinkRequests(!administering)
  const unlinked = useQuery(
    UnlinkedMachinesDocument,
    {},
    { skip: !administering },
  )

  useEffect(() => {
    if (!checking) return

    const polling = window.setInterval(refetch, CHECKING_POLL)
    return () => window.clearInterval(polling)
  }, [checking, refetch])

  const closeAdding = () => {
    setAdding(null)
    if (!params.has('attach')) return

    const rest = new URLSearchParams(params)
    rest.delete('attach')
    setParams(rest, { replace: true })
  }

  if (loading && !data) return <Loader size="sm" color="var(--accent)" />
  if (error) return <Failed error={error} retry={refetch} />

  const resources = (data?.resources ?? []) as Resource[]
  const administrator = data?.administrator ?? false
  const linkUp = (data?.linkUp ?? null) as LinkUpInfo | null
  const transports = resources
    .filter((resource) => resource.capabilities.includes('transport'))
    .map((resource) => resource.key)
  const groups = shelved ? [] : grouped(resources)
  const pooled = shelved
    ? null
    : waitingForAny((data?.waitingForMachines ?? []) as Waiting[])
  const places = groups.map((group) => group.place)
  const placeNamed = (id?: string | null) =>
    groups.find((group) => group.rows.some((row) => row.id === id))?.place
      .name ?? THIS_SERVER

  const acts: Acts = {
    check: async (resource) => {
      const answered = await check.execute({ id: resource.id })

      if (!answered) return

      const checked = answered.checkResource?.resource

      if (checked?.offline) {
        say({
          text: `${resource.key} is offline. ${told({ ...resource, ...checked })}.`,
        })
        refetch()
        return
      }

      say(
        answered.checkResource?.ok
          ? {
              text: answered.checkResource.resource.checking
                ? `${resource.key} answers. Its models are being tried now.`
                : `${resource.key} answers.`,
            }
          : {
              text:
                unraised(answered.checkResource?.resource.checkError) ??
                `${resource.key} did not answer.`,
              wrong: true,
            },
      )
      refetch()
    },
    sync: async (resource) => {
      const answered = await sync.execute({ id: resource.id })

      if (!answered) return

      say({ text: `${resource.key} is syncing.` })
      refetch()
    },
    takeDrops: async (resource) => {
      const answered = await takeDrops.execute({ id: resource.id })

      if (!answered) return

      say({ text: `Drops land in ${resource.key} now.` })
      refetch()
    },
    takeQuestions: async (resource) => {
      const answered = await takeQuestions.execute({ id: resource.id })

      if (!answered) return

      say({ text: `${resource.key} answers questions now.` })
      refetch()
    },
    schedule: async (resource, seconds) => {
      const answered = await setInterval.execute({ id: resource.id, seconds })

      if (!answered) return false

      say({
        text: seconds
          ? `${resource.key} syncs every ${Math.round(seconds / 60)} minutes.`
          : `${resource.key} syncs on demand only.`,
      })
      refetch()
      return true
    },
    change: (resource) => setEditing(resource),
    history: (resource) => setHistory(resource),
    putAway,
    remove: (resource) => setDeleting(resource),
  }

  const drops = resources.find((resource) => resource.defaultStorage)
  const questions = resources.find((resource) => resource.defaultInference)
  const goTo = (resource: Resource) =>
    document
      .getElementById(`resource-${resource.id}`)
      ?.scrollIntoView({ block: 'center', behavior: 'smooth' })

  const row = (resource: Resource, group?: Group) => (
    <ResourceRow
      key={resource.id}
      resource={resource}
      through={
        group?.place.local &&
        resource.via &&
        resource.via !== LOCAL &&
        resource.type !== MACHINE
          ? resource.via
          : null
      }
      away={Boolean(
        group?.machine?.machine?.linked && !group.machine.machine.connected,
      )}
      landed={resource.id === landed}
      landedRef={resource.id === landed ? arrived : undefined}
      putting={putting === resource.id}
      administrator={administrator}
      acts={acts}
    />
  )

  return (
    <div className="settings-page">
      {connectError && (
        <Alert
          color="red"
          title="That did not connect"
          withCloseButton
          onClose={() => {
            setConnectError(null)
            window.history.replaceState(null, '', window.location.pathname)
          }}
        >
          {connectError}
        </Alert>
      )}

      <Intro
        title="Resources"
        lead={
          shelved
            ? 'Put away, and still holding everything they ever catalogued.'
            : 'Each machine, and what lives on it or is reached from it.'
        }
      >
        <div className="switcher" data-wide="true">
          <button
            type="button"
            data-on={!shelved}
            aria-pressed={!shelved}
            onClick={() => setShelved(false)}
          >
            In use
          </button>
          <button
            type="button"
            data-on={shelved}
            aria-pressed={shelved}
            onClick={() => setShelved(true)}
          >
            Put away
          </button>
        </div>

        {!shelved && (
          <Button
            radius="xl"
            variant="default"
            leftSection={<IconPlus size={16} stroke={2} />}
            onClick={() => setAdding({ place: LOCAL, choosing: true })}
          >
            Add
          </Button>
        )}
      </Intro>

      {!administrator && !shelved && (
        <p className="quiet-note">
          <IconShieldLock size={15} stroke={1.8} />
          <span>Places everyone shares are changed by an administrator.</span>
          <a href={administratorSignIn()}>Sign in as one</a>
        </p>
      )}

      {!shelved && (
        <p className="defaults-line">
          <span>
            <IconStar size={14} stroke={1.8} />
            {drops ? (
              <>
                Drops land in{' '}
                <button type="button" onClick={() => goTo(drops)}>
                  {named(drops)}
                </button>{' '}
                on {placeNamed(drops.id)}
              </>
            ) : (
              'Nothing takes drops yet'
            )}
          </span>
          <span>
            <IconSparkles size={14} stroke={1.8} />
            {questions ? (
              <>
                Questions go to{' '}
                <button type="button" onClick={() => goTo(questions)}>
                  {named(questions)}
                </button>{' '}
                on {placeNamed(questions.id)}
              </>
            ) : (
              'Nothing answers questions yet'
            )}
          </span>
        </p>
      )}

      {linkingUp && linkUp && (
        <LinkUpDialog
          info={linkUp}
          requests={asking.requests}
          onClose={() => setLinkingUp(false)}
          onChanged={() => {
            asking.refetch()
            refetch()
          }}
        />
      )}

      {!shelved && administrator && (
        <AskingLine
          requests={asking.requests}
          onReview={() => setLinkingUp(true)}
        />
      )}

      {adding && places.length > 0 && (
        <AddTo
          places={places}
          start={
            places.find((place) => place.key === adding.place) ?? places[0]
          }
          choosing={adding.choosing}
          held={resources}
          administrator={administrator}
          onForm={(next) => {
            closeAdding()
            setForm(next)
          }}
          onAdded={refetch}
          onClose={closeAdding}
        />
      )}

      {form && (
        <Attach
          opened
          administrator={administrator}
          transports={transports}
          initialType={form.type}
          initialVia={form.via}
          initialKey={form.key}
          initialSettings={form.settings}
          initialShelf={form.shelf}
          onClose={() => setForm(null)}
          onAttached={refetch}
        />
      )}

      {editing && (
        <Attach
          opened
          transports={transports}
          editing={editing}
          onClose={() => setEditing(null)}
          onAttached={refetch}
        />
      )}

      {pooled && <p className="machine-waiting">{pooled}</p>}

      {groups.map((group) => (
        <MachineCard
          key={group.place.key}
          group={group}
          landed={group.machine?.id === landed}
          landedRef={group.machine?.id === landed ? arrived : undefined}
          putting={group.machine ? putting === group.machine.id : false}
          administrator={administrator}
          acts={acts}
          onAdd={() => setAdding({ place: group.place.key, choosing: false })}
          onChanged={refetch}
        >
          {placed(group.rows).map((resource) => row(resource, group))}
        </MachineCard>
      ))}

      {!shelved && administrator && (
        <Unlinked
          nodes={(unlinked.data?.unlinkedMachines ?? []) as Peer[]}
          held={resources}
          onLinkUp={() => setLinkingUp(true)}
          onAdded={() => {
            unlinked.refetch()
            refetch()
          }}
        />
      )}

      {!shelved && administrator && linkUp && (
        <LinkUpTile onLinkUp={() => setLinkingUp(true)} />
      )}

      {shelved && resources.length > 0 && (
        <section className="machine-card">
          <ul className="machine-rows">
            {resources.map((resource) => row(resource))}
          </ul>
        </section>
      )}

      {history && (
        <RunsDialog resource={history} onClose={() => setHistory(null)} />
      )}

      {deleting && (
        <Sure
          opened
          onClose={() => setDeleting(null)}
          title={`Delete ${deleting.key}?`}
          verb="Delete it"
          loading={remove.loading}
          onSure={() => deleteIt(deleting)}
        >
          xixo stops pointing at the{' '}
          <strong>
            {deleting.itemsCount.toLocaleString()}{' '}
            {deleting.itemsCount === 1 ? 'item' : 'items'}
          </strong>{' '}
          it catalogued and frees the key <strong>{deleting.key}</strong>. An
          item found nowhere else is forgotten, unless it has a note, a
          lifetime, or a tag or connection someone made. What the resource holds
          is not touched, except a <span className="mono">database</span>{' '}
          resource, whose files live in xixo and are deleted with it.
        </Sure>
      )}

      {shelved && resources.length === 0 && (
        <div className="settings-empty">
          Nothing has been put away. A resource you stop using goes here, and
          what it catalogued stays searchable until you delete it.
        </div>
      )}
    </div>
  )
}

export function administratorSignIn() {
  const url = new URL(
    session.loginUrl({ returnTo: window.location.pathname }),
    window.location.origin,
  )
  url.searchParams.set('privilege', 'admin')

  return `${url.pathname}${url.search}`
}

interface Acts {
  check: (resource: Resource) => void
  sync: (resource: Resource) => void
  takeDrops: (resource: Resource) => void
  takeQuestions: (resource: Resource) => void
  schedule: (resource: Resource, seconds: number | null) => Promise<boolean>
  change: (resource: Resource) => void
  history: (resource: Resource) => void
  putAway: (resource: Resource, archived: boolean) => void
  remove: (resource: Resource) => void
}

function MachineCard({
  group,
  landed,
  landedRef,
  putting,
  administrator,
  acts,
  onAdd,
  onChanged,
  children,
}: {
  group: Group
  landed: boolean
  landedRef?: RefObject<HTMLElement | null>
  putting: boolean
  administrator: boolean
  acts: Acts
  onAdd: () => void
  onChanged: () => void
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)
  const { machine: resource, place } = group
  const machine = resource?.machine
  const state = resource ? status(resource) : null
  const away = Boolean(machine?.linked && !machine.connected)
  const problem =
    resource?.checkError && !resource.checking && !away
      ? humane(resource.checkError)
      : null
  const said = machine ? facts(machine, place) : []
  const low = machine ? warning(machine) : null
  const found = place.services.filter(
    (service) => !addedAs(place, service, group.rows),
  )
  const addable = administrator || place.local
  const quickly = useQuickAdd(administrator, onChanged)

  return (
    <section
      ref={landedRef}
      className="machine-card"
      data-landed={landed}
      data-away={away}
      aria-labelledby={`machine-${place.key}`}
      style={{ '--state': state?.tone } as CSSProperties}
    >
      <header className="machine-head">
        <span className="machine-icon">
          {place.local ? (
            <IconServer size={20} stroke={1.6} />
          ) : (
            <MachineIcon
              os={machine?.os}
              system={machine?.system}
              kind={machine?.kind}
            />
          )}
        </span>

        <div className="machine-name">
          <h2 id={`machine-${place.key}`} className="machine-title">
            {place.name}
          </h2>
          <div className="machine-sub">
            {resource ? system(resource) : 'Where xixo runs'}
          </div>
        </div>

        {state?.said && (
          <span
            className="machine-state"
            data-busy={state.busy}
            title={resource ? told(resource) : undefined}
          >
            {state.said}
          </span>
        )}

        {resource && (
          <div className="machine-acts">
            <More
              resource={resource}
              administrator={administrator}
              putting={putting}
              open={open}
              onDetails={() => setOpen((held) => !held)}
              acts={acts}
            />
          </div>
        )}
      </header>

      {said.length > 0 && <p className="machine-facts">{said.join(' · ')}</p>}

      {resource && machine?.linked && (
        <Access
          resource={resource}
          administrator={administrator}
          onChanged={onChanged}
        />
      )}

      {found.map((service) => {
        const named = SERVERS[service.kind] ?? service.kind

        const quick =
          administrator || place.local ? quickFor(place, service) : null

        return (
          <p key={`${service.kind}-${service.port}`} className="machine-found">
            <IconCpu size={15} stroke={1.8} />
            <span>
              Found {named} on {place.name}
            </span>
            {quick && (
              <Button
                size="compact-xs"
                radius="xl"
                variant="default"
                aria-label={`Add ${quick.name}`}
                loading={quickly.busy === quick.key}
                onClick={() => quickly.add(quick)}
              >
                Add
              </Button>
            )}
          </p>
        )
      })}

      {problem && <div className="rrow-error">{problem}</div>}
      {low && <div className="rrow-notice">{low}</div>}
      {machine?.warnings.map((held) => (
        <div key={held} className="rrow-notice">
          {held}
        </div>
      ))}

      {open && resource && <Details resource={resource} acts={acts} />}

      <ul className="machine-rows">{children}</ul>

      {addable && (
        <button type="button" className="machine-add" onClick={onAdd}>
          <IconPlus size={15} stroke={2} />
          Add to {place.name}
        </button>
      )}
    </section>
  )
}

const LEVELS = [
  { value: 'search', label: 'Search' },
  { value: 'files', label: 'Files' },
  { value: 'writing', label: 'Files and writing' },
]

const LEVEL_SAYS: Record<string, string> = {
  search: 'Browse, search, and read the text xixo drew out.',
  files: 'Also fetch whole files and run its readers.',
  writing: 'Also write into the folders it marks writable.',
}

function Access({
  resource,
  administrator,
  onChanged,
}: {
  resource: Resource
  administrator: boolean
  onChanged: () => void
}) {
  const set = useAloud(SetMachineAccessDocument, 'That could not be changed.')
  const machine = resource.machine
  if (!machine) return null

  const change = async (asked: { access?: string; helpsOthers?: boolean }) => {
    const answered = await set.execute({ id: resource.id, ...asked })
    if (answered) onChanged()
  }

  const level =
    LEVELS.find((held) => held.value === machine.access) ?? LEVELS[0]

  if (!administrator)
    return (
      <p className="machine-access-says">
        {level.label}. {LEVEL_SAYS[level.value]}
      </p>
    )

  return (
    <div className="machine-access">
      <SegmentedControl
        size="xs"
        aria-label={`What xixo may do with ${resource.key}`}
        value={level.value}
        data={LEVELS}
        disabled={set.loading}
        onChange={(access) => change({ access })}
      />
      <span className="machine-access-says">{LEVEL_SAYS[level.value]}</span>
      <Switch
        size="xs"
        label="Help read other machines' files"
        checked={machine.helpsOthers}
        disabled={set.loading}
        onChange={(event) =>
          change({ helpsOthers: event.currentTarget.checked })
        }
      />
    </div>
  )
}

interface Peer {
  hostName?: string | null
  dnsName?: string | null
  addresses: string[]
  via?: string | null
  services: { name: string; port: number; type: string; address: string }[]
}

const KINDS: Record<string, string> = { 'lm-studio': 'lmstudio' }

function keyed(text: string) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

function Unlinked({
  nodes,
  held,
  onLinkUp,
  onAdded,
}: {
  nodes: Peer[]
  held: Resource[]
  onLinkUp: () => void
  onAdded: () => void
}) {
  const quickly = useQuickAdd(true, onAdded)

  if (nodes.length === 0) return null

  return (
    <section className="unlinked" aria-labelledby="unlinked-title">
      <h2 id="unlinked-title" className="label">
        Not linked yet
      </h2>
      <ul className="unlinked-list">
        {nodes.map((node) => {
          const name =
            node.hostName ?? node.dnsName ?? node.addresses[0] ?? 'a machine'
          const models = node.services
            .filter((service) => service.type === 'openai-compatible')
            .map((service) => {
              const kind = KINDS[service.name] ?? service.name
              const label = SERVERS[kind] ?? kind

              return {
                kind,
                url: service.address,
                via: node.via ?? null,
                key: `${kind}-${keyed(name)}`,
                name: `${label} on ${name}`,
                label,
              }
            })
            .filter(
              (quick) =>
                !held.some(
                  (resource) =>
                    resource.key === quick.key ||
                    resource.settings.base_url === quick.url,
                ),
            )

          return (
            <li key={node.addresses[0] ?? name} className="unlinked-row">
              <span className="unlinked-name">{name}</span>
              {models.map((quick) => (
                <span key={quick.key} className="unlinked-found">
                  Found {quick.label}
                  <Button
                    size="compact-xs"
                    radius="xl"
                    variant="default"
                    aria-label={`Add ${quick.name}`}
                    loading={quickly.busy === quick.key}
                    onClick={() => quickly.add(quick)}
                  >
                    Add
                  </Button>
                </span>
              ))}
              <Button
                size="compact-xs"
                radius="xl"
                variant="subtle"
                color="brand"
                className="link-mark-hover"
                leftSection={<LinkMark size={14} />}
                onClick={onLinkUp}
              >
                Link up
              </Button>
            </li>
          )
        })}
      </ul>
    </section>
  )
}

function ResourceRow({
  resource,
  through,
  away,
  landed,
  landedRef,
  putting,
  administrator,
  acts,
}: {
  resource: Resource
  through: string | null
  away: boolean
  landed: boolean
  landedRef?: RefObject<HTMLElement | null>
  putting: boolean
  administrator: boolean
  acts: Acts
}) {
  const [open, setOpen] = useState(false)
  const Glyph = glyphFor(resource.type)
  const state = status(resource)
  const problem =
    resource.checkError && !resource.checking && !resource.offline && !away
      ? humane(resource.checkError)
      : null
  const wrong = state.wrong && !away
  const folder =
    resource.type === 'filesystem' ? `${resource.settings.folder ?? ''}` : null
  const counted = resource.capabilities.includes('storage')

  return (
    <li
      ref={(node) => {
        if (landedRef) landedRef.current = node
      }}
      id={`resource-${resource.id}`}
      className="rrow"
      data-landed={landed}
      data-failing={wrong}
      style={{ '--state': state.tone } as CSSProperties}
    >
      <span className="rrow-icon">
        <Glyph size={17} stroke={1.7} />
      </span>

      <div className="rrow-main">
        <div className="rrow-name">
          <h3>{named(resource)}</h3>
          {resource.defaultStorage && (
            <span className="rrow-badge">
              <IconStar size={11} stroke={2} /> drops land here
            </span>
          )}
          {resource.defaultInference && (
            <span className="rrow-badge">
              <IconSparkles size={11} stroke={2} /> answers questions
            </span>
          )}
          {resource.personal && (
            <span className="rrow-badge" data-plain="true">
              <IconLock size={11} stroke={2} /> only you
            </span>
          )}
        </div>
        <div className="rrow-says">
          {folder === null &&
            [
              does(resource),
              counted ? plural(resource.itemsCount, 'item') : null,
              through ? `through ${through}` : null,
            ]
              .filter(Boolean)
              .join(' · ')}
          {folder !== null && (
            <>
              <span className="mono">{folder}</span>
              {counted && ` · ${plural(resource.itemsCount, 'item')}`}
            </>
          )}
        </div>
      </div>

      {state.said && (wrong || state.busy || resource.offline) && (
        <span
          className="rrow-state"
          data-busy={state.busy}
          title={told(resource)}
        >
          {state.said}
        </span>
      )}

      <div className="rrow-acts">
        {resource.archivedAt ? (
          resource.manageable && (
            <>
              <Button
                size="compact-sm"
                radius="xl"
                variant="subtle"
                color="red"
                leftSection={<IconTrash size={14} />}
                disabled={putting}
                onClick={() => acts.remove(resource)}
              >
                Delete
              </Button>
              <Button
                size="compact-sm"
                radius="xl"
                variant="default"
                leftSection={<IconArchiveOff size={14} />}
                loading={putting}
                onClick={() => acts.putAway(resource, false)}
              >
                Put back
              </Button>
            </>
          )
        ) : (
          <>
            {resource.manageable &&
              resource.delegated &&
              resource.needsConnect &&
              resource.connectUrl && (
                <Button
                  component="a"
                  href={resource.connectUrl}
                  size="compact-sm"
                  radius="xl"
                  color="brand"
                  leftSection={<IconPlugConnected size={14} />}
                >
                  {resource.connectedBy ? 'Reconnect' : 'Connect'}
                </Button>
              )}
            <More
              resource={resource}
              administrator={administrator}
              putting={putting}
              compact
              open={open}
              onDetails={() => setOpen((held) => !held)}
              acts={acts}
            />
          </>
        )}
      </div>

      {problem && <div className="rrow-error">{problem}</div>}

      {resource.emptiedAt && (
        <div className="rrow-error">
          The sync {ago(resource.emptiedAt)} found nothing here, so its items
          stay until a sync finds files again
        </div>
      )}

      {open && <Details resource={resource} acts={acts} />}
    </li>
  )
}

function More({
  resource,
  administrator,
  putting,
  compact = false,
  open,
  onDetails,
  acts,
}: {
  resource: Resource
  administrator: boolean
  putting: boolean
  compact?: boolean
  open: boolean
  onDetails: () => void
  acts: Acts
}) {
  return (
    <>
      <button
        type="button"
        className="rrow-more"
        aria-expanded={open}
        aria-label={`Details of ${resource.key}`}
        onClick={onDetails}
      >
        {compact ? null : 'Details'}
        <IconChevronDown size={14} stroke={1.8} data-open={open} />
      </button>
      <Menu position="bottom-end" width={220}>
        <Menu.Target>
          <ActionIcon
            size={30}
            radius="xl"
            variant="subtle"
            color="gray"
            aria-label={`More for ${resource.key}`}
          >
            <IconDots size={16} stroke={1.8} />
          </ActionIcon>
        </Menu.Target>
        <Menu.Dropdown>
          {resource.syncable && (
            <Menu.Item
              leftSection={<IconRefresh size={15} />}
              disabled={resource.syncing}
              onClick={() => acts.sync(resource)}
            >
              Sync now
            </Menu.Item>
          )}
          <Menu.Item
            leftSection={<IconCheck size={15} />}
            onClick={() => acts.check(resource)}
          >
            Check
          </Menu.Item>
          <Menu.Item
            leftSection={<IconHistory size={15} />}
            onClick={() => acts.history(resource)}
          >
            What it has done
          </Menu.Item>
          {resource.manageable &&
            resource.delegated &&
            !resource.needsConnect &&
            resource.connectUrl && (
              <Menu.Item
                component="a"
                href={resource.connectUrl}
                leftSection={<IconPlugConnected size={15} />}
              >
                Connect again
              </Menu.Item>
            )}
          {resource.manageable && (
            <>
              {administrator && resource.capabilities.includes('storage') && (
                <Menu.Item
                  disabled={resource.defaultStorage}
                  leftSection={<IconStar size={15} />}
                  onClick={() => acts.takeDrops(resource)}
                >
                  Take drops
                </Menu.Item>
              )}
              {administrator && resource.capabilities.includes('inference') && (
                <Menu.Item
                  disabled={resource.defaultInference}
                  leftSection={<IconSparkles size={15} />}
                  onClick={() => acts.takeQuestions(resource)}
                >
                  Take questions
                </Menu.Item>
              )}
              {resource.changeable && (
                <Menu.Item
                  leftSection={<IconPencil size={15} />}
                  onClick={() => acts.change(resource)}
                >
                  Change
                </Menu.Item>
              )}
              <Menu.Divider />
              <Menu.Item
                leftSection={<IconArchive size={15} />}
                disabled={putting}
                onClick={() => acts.putAway(resource, true)}
              >
                Put away
              </Menu.Item>
            </>
          )}
        </Menu.Dropdown>
      </Menu>
    </>
  )
}

function Details({ resource, acts }: { resource: Resource; acts: Acts }) {
  const machine = resource.machine
  const rows: [string, ReactNode][] = [
    [
      'Key',
      <span key="key" className="mono">
        {resource.key}
      </span>,
    ],
    [
      'Type',
      <span key="type" className="mono">
        {resource.type}
      </span>,
    ],
    ...(resource.via && resource.type !== MACHINE
      ? ([['Reached through', resource.via]] as [string, ReactNode][])
      : []),
    ['Does', resource.capabilities.join(', ') || 'nothing on its own'],
  ]

  if (resource.syncable)
    rows.push([
      'Syncs',
      <Every
        key="every"
        resource={resource}
        onKeep={resource.manageable ? acts.schedule : undefined}
      />,
    ])

  if (machine) {
    const held = [machine.hostname, machine.os, machine.arch]
      .filter(Boolean)
      .join(', ')
    const health = [upFor(machine.uptime), memory(machine), ...disks(machine)]
      .filter(Boolean)
      .join('. ')

    if (held) rows.push(['Machine', held])
    if (resource.via) rows.push(['Reached through', resource.via])
    if (machine.version) rows.push(['xixo link', machine.version])
    if (machine.folders.length > 0)
      rows.push([
        'Folders',
        <span key="folders" className="mono">
          {machine.folders.join('\n')}
        </span>,
      ])
    if (machine.unread.length > 0)
      rows.push(['Cannot read', cannotRead(machine.unread)])
    rows.push([
      'Offers MCP clients',
      machine.tools.length > 0 ? machine.tools.join(', ') : 'no tools',
    ])
    rows.push([
      'Whole files',
      machine.lends ? 'xixo may fetch them' : 'stay on the machine',
    ])
    if (machine.services.length > 0)
      rows.push([
        'Model servers',
        machine.services
          .map(
            (service) =>
              `${SERVERS[service.kind] ?? service.kind} on port ${service.port}${service.address ? ` at ${service.address}` : ''}`,
          )
          .join('\n'),
      ])
    if (health) rows.push(['Health', health])
  }

  rows.push([
    'Checked',
    resource.checkedAt ? ago(resource.checkedAt) : 'not yet',
  ])
  if (resource.checkError)
    rows.push(['What it said', unraised(resource.checkError)])

  return (
    <dl className="rdetails">
      {rows.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  )
}

function Every({
  resource,
  onKeep,
}: {
  resource: Resource
  onKeep?: (resource: Resource, seconds: number | null) => Promise<boolean>
}) {
  const [open, setOpen] = useState(false)
  const [minutes, setMinutes] = useState<number | string>(
    resource.syncInterval ? resource.syncInterval / 60 : '',
  )
  const [busy, setBusy] = useState(false)

  const said = resource.syncing
    ? 'syncing now'
    : [
        resource.syncInterval
          ? `every ${Math.round(resource.syncInterval / 60)} min`
          : 'on demand',
        resource.syncedAt ? `synced ${dated(resource.syncedAt)}` : null,
      ]
        .filter(Boolean)
        .join(' · ')

  if (!onKeep) {
    return (
      <span className="rdetails-when">
        <IconClock size={13} stroke={1.8} />
        {said}
      </span>
    )
  }

  return (
    <Popover
      opened={open}
      onChange={setOpen}
      position="top-start"
      width={260}
      shadow="xl"
      radius="md"
      trapFocus
    >
      <Popover.Target>
        <button
          type="button"
          className="rdetails-when rdetails-every"
          aria-label={`Sync schedule for ${resource.key}: ${said}`}
          onClick={() => setOpen((held) => !held)}
        >
          <IconClock size={13} stroke={1.8} />
          {said}
        </button>
      </Popover.Target>
      <Popover.Dropdown>
        <form
          className="every-form"
          onSubmit={async (event) => {
            event.preventDefault()

            const value = Number(minutes)
            const seconds = value > 0 ? Math.round(value * 60) : null

            setBusy(true)
            const kept = await onKeep(resource, seconds).finally(() =>
              setBusy(false),
            )

            if (kept) setOpen(false)
          }}
        >
          <div className="label">Sync every</div>
          <div className="every-row">
            <NumberInput
              min={1}
              hideControls
              placeholder="on demand"
              aria-label={`Minutes between syncs of ${resource.key}`}
              value={minutes}
              onChange={setMinutes}
              rightSection={<span className="every-unit">min</span>}
              rightSectionWidth={44}
              style={{ flex: 1 }}
            />
            <Button type="submit" color="brand" loading={busy}>
              Keep
            </Button>
          </div>
          <div className="every-note">
            Leave it empty to sync on demand only.
          </div>
        </form>
      </Popover.Dropdown>
    </Popover>
  )
}
