import {
  ActionIcon,
  Alert,
  Button,
  Loader,
  Menu,
  NumberInput,
  Popover,
  Tooltip,
} from '@mantine/core'
import {
  IconArchive,
  IconArchiveOff,
  IconCheck,
  IconChevronDown,
  IconClock,
  IconDots,
  IconHistory,
  IconLink,
  IconLock,
  IconPencil,
  IconPlugConnected,
  IconPlus,
  IconRefresh,
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
  SetSyncIntervalDocument,
  SyncResourceDocument,
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
  warning,
} from '../plain'
import { unraised } from '../shared'
import { ago, dated } from '../when'
import { Attach, type Editing, glyphFor } from './Attach'
import { Failed } from './Failed'
import {
  LinkUpDialog,
  type LinkUpInfo,
  LinkUpPanel,
  type Machine,
} from './LinkUp'
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
  machine?: {
    hostname?: string | null
    version?: string | null
    connected: boolean
    seenAt?: string | null
    uptime?: number | null
    folders: string[]
    extractors: string[]
    unread: string[]
    lends: boolean
    tools: string[]
    warnings: string[]
    os?: string | null
    arch?: string | null
    extractsForOthers?: boolean | null
    linked: boolean
    selfLinked: boolean
    linkingUntil?: string | null
    services: { kind: string; port: number }[]
    memoryTotal?: number | string | null
    memoryAvailable?: number | string | null
    disks: {
      path: string
      total?: number | string | null
      free?: number | string | null
    }[]
  } | null
}

const MACHINE = 'xixo-agent'
const LOCAL = 'local'

const CHECKING_POLL = 2000

interface Status {
  tone: string
  said: string | null
  busy: boolean
}

function status(resource: Resource): Status {
  const machine = resource.machine

  if (resource.syncing)
    return { tone: 'var(--busy)', said: 'syncing', busy: true }
  if (resource.needsConnect)
    return {
      tone: 'var(--bad)',
      said: resource.connectedBy ? 'needs reconnecting' : 'not connected',
      busy: false,
    }
  if (resource.checking)
    return { tone: 'var(--busy)', said: 'checking', busy: true }
  if (machine?.linkingUntil)
    return { tone: 'var(--busy)', said: 'waiting to link up', busy: true }
  if (machine && !machine.linked && resource.key !== LOCAL)
    return { tone: 'var(--edge)', said: 'not linked', busy: false }
  if (machine)
    return machine.connected
      ? { tone: 'var(--ok)', said: null, busy: false }
      : { tone: 'var(--away)', said: 'offline', busy: false }
  if (resource.offline)
    return { tone: 'var(--away)', said: 'offline', busy: false }
  if (!resource.checkedAt)
    return { tone: 'var(--edge)', said: null, busy: false }

  return resource.healthy
    ? { tone: 'var(--ok)', said: null, busy: false }
    : { tone: 'var(--bad)', said: 'not working', busy: false }
}

function told(resource: Resource) {
  if (resource.offline) {
    const host = resource.offlineHost ?? 'its machine'

    return resource.offlineLastSeenAt
      ? `${host} was last seen ${ago(resource.offlineLastSeenAt)}`
      : `${host} has not been seen on ${resource.via ?? 'its network'}`
  }

  if (resource.machine && !resource.machine.connected)
    return lastSeen(resource.machine) ?? 'not connected'

  if (resource.checkError) return humane(resource.checkError)

  return resource.checkedAt
    ? `checked ${ago(resource.checkedAt)}`
    : 'not checked yet'
}

function plural(count: number, one: string, many = `${one}s`) {
  return `${count} ${count === 1 ? one : many}`
}

const MODELS: Record<string, string> = {
  ollama: 'Ollama',
  lmstudio: 'LM Studio',
}

function machineLines(machine: NonNullable<Resource['machine']>) {
  if (!machine.linked && !machine.connected && !machine.seenAt) return []

  const models = [...new Set(machine.services.map((held) => held.kind))]
    .map((kind) => MODELS[kind] ?? kind)
    .join(' and ')
  const helps = [
    machine.extractsForOthers && 'reads for other machines',
    machine.lends && 'sends what it cannot read to the server',
  ].filter(Boolean)

  return [
    machine.connected ? null : lastSeen(machine)?.replace(/^l/, 'L'),
    machine.folders.length === 0
      ? 'Shares no folders yet'
      : `Shares ${plural(machine.folders.length, 'folder')}`,
    reads(machine.extractors, machine.unread),
    helps.length > 0 ? `Also ${helps.join(' and ')}` : null,
    models ? `Has ${models}` : null,
    warning(machine),
  ].filter((line): line is string => Boolean(line))
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
  const [attaching, setAttaching] = useState(params.has('attach'))
  const [editing, setEditing] = useState<Editing | null>(null)
  const [linkingUp, setLinkingUp] = useState(false)
  const [relinking, setRelinking] = useState<Machine | null>(null)
  const [installing, setInstalling] = useState(false)
  const [history, setHistory] = useState<Resource | null>(null)
  const arrived = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (landed) arrived.current?.scrollIntoView({ block: 'center' })
  }, [landed])

  const checking = (data?.resources ?? []).some((resource) => resource.checking)

  useEffect(() => {
    if (!checking) return

    const polling = window.setInterval(refetch, CHECKING_POLL)
    return () => window.clearInterval(polling)
  }, [checking, refetch])

  const closeAttach = () => {
    setAttaching(false)
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
    relink: (resource) => setRelinking(resource),
    history: (resource) => setHistory(resource),
    putAway,
    remove: (resource) => setDeleting(resource),
  }

  const inUse = (key: Shelf) =>
    resources.filter((resource) => shelfOf(resource) === key)
  const machineCards = inUse('machines').sort((a, b) =>
    a.key === LOCAL ? -1 : b.key === LOCAL ? 1 : a.key.localeCompare(b.key),
  )

  const card = (resource: Resource) => (
    <ResourceCard
      key={resource.id}
      resource={resource}
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
            : 'Your machines, where your files live, what reads them, and the tools agents reach for.'
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
            onClick={() => setAttaching(true)}
          >
            Attach
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

      {linkingUp || relinking ? (
        <LinkUpDialog
          info={linkUp}
          relinking={relinking}
          onClose={() => {
            setLinkingUp(false)
            setRelinking(null)
          }}
          onChanged={refetch}
          onSsh={() => {
            setLinkingUp(false)
            setInstalling(true)
          }}
        />
      ) : null}

      {installing && (
        <Attach
          opened
          administrator={administrator}
          transports={transports}
          initialType={MACHINE}
          onClose={() => setInstalling(false)}
          onAttached={refetch}
        />
      )}

      {attaching && (
        <Attach
          opened
          administrator={administrator}
          transports={transports}
          onLinkUp={() => {
            closeAttach()
            setLinkingUp(true)
          }}
          onClose={closeAttach}
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

      {!shelved && (
        <section className="shelf-group" data-shelf="machines">
          <div className="shelf-group-head">
            <h2 className="label">Machines</h2>
            <span className="shelf-group-note">
              The computers that make up your xixo
            </span>
          </div>

          <LinkUpPanel
            administrator={administrator}
            onLinkUp={() => setLinkingUp(true)}
          />

          {machineCards.length > 0 && (
            <div className="rcards">{machineCards.map(card)}</div>
          )}
        </section>
      )}

      {SHELVES.filter((shelf) => !(shelf.key === 'machines' && !shelved)).map(
        (shelf) => {
          const held = inUse(shelf.key)
          if (held.length === 0) return null

          return (
            <section
              key={shelf.key}
              className="shelf-group"
              data-shelf={shelf.key}
            >
              <div className="shelf-group-head">
                <h2 className="label">{shelf.title}</h2>
                <span className="shelf-group-note">{shelf.note}</span>
              </div>

              <div
                className="rcards"
                data-compact={
                  shelf.key === 'tools' || shelf.key === 'connections'
                }
              >
                {held.map(card)}
              </div>
            </section>
          )
        },
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

function administratorSignIn() {
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
  relink: (resource: Resource) => void
  history: (resource: Resource) => void
  putAway: (resource: Resource, archived: boolean) => void
  remove: (resource: Resource) => void
}

const SHELVES = [
  {
    key: 'machines',
    title: 'Machines',
    note: 'The computers that make up your xixo',
    tone: 'var(--accent)',
  },
  {
    key: 'storage',
    title: 'Storage',
    note: 'Where your files live',
    tone: 'var(--k-text)',
  },
  {
    key: 'models',
    title: 'Models',
    note: 'What reads and answers',
    tone: 'var(--k-image)',
  },
  {
    key: 'tools',
    title: 'Tools',
    note: 'What agents can reach for',
    tone: 'var(--k-data)',
  },
  {
    key: 'connections',
    title: 'Connections',
    note: 'How xixo reaches the others',
    tone: 'var(--k-file)',
  },
] as const

type Shelf = (typeof SHELVES)[number]['key']

function shelfOf(resource: Resource): Shelf {
  if (resource.type === MACHINE) return 'machines'
  if (resource.capabilities.includes('storage')) return 'storage'
  if (resource.capabilities.includes('inference')) return 'models'
  if (resource.capabilities.includes('transport')) return 'connections'

  return 'tools'
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
    ...(resource.via
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
    const system = [machine.hostname, machine.os, machine.arch]
      .filter(Boolean)
      .join(', ')
    const health = [upFor(machine.uptime), memory(machine), ...disks(machine)]
      .filter(Boolean)
      .join('. ')

    if (system) rows.push(['Machine', system])
    if (machine.version) rows.push(['Agent', machine.version])
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
    if (health) rows.push(['Health', health])
  }

  rows.push([
    'Checked',
    resource.checkedAt ? ago(resource.checkedAt) : 'not yet',
  ])
  if (resource.checkError)
    rows.push(['What it said', unraised(resource.checkError)])

  return (
    <dl className="rcard-details">
      {rows.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  )
}

function ResourceCard({
  resource,
  landed,
  landedRef,
  putting,
  administrator,
  acts,
}: {
  resource: Resource
  landed: boolean
  landedRef?: RefObject<HTMLElement | null>
  putting: boolean
  administrator: boolean
  acts: Acts
}) {
  const [open, setOpen] = useState(false)
  const Glyph = glyphFor(resource.type)
  const shelf = shelfOf(resource)
  const tone = SHELVES.find((held) => held.key === shelf)?.tone
  const state = status(resource)
  const machine = resource.machine
  const linkable =
    administrator && resource.type === MACHINE && resource.key !== LOCAL
  const unlinked = linkable && !machine?.linked && !machine?.linkingUntil
  const problem =
    resource.checkError &&
    !resource.checking &&
    !machine?.linkingUntil &&
    !(machine?.linked && !machine.connected)
      ? humane(resource.checkError)
      : null
  const lines = machine ? machineLines(machine) : []

  return (
    <article
      ref={landedRef}
      className="rcard"
      data-landed={landed}
      data-failing={Boolean(
        (resource.checkError && !resource.checking) || resource.needsConnect,
      )}
      style={{ '--tone': tone, '--state': state.tone } as CSSProperties}
    >
      <div className="rcard-top">
        <span className="rcard-icon">
          <Glyph size={20} stroke={1.6} />
        </span>

        <div className="rcard-name">
          <h3 className="rcard-key">{resource.name || resource.key}</h3>
          <div className="rcard-kind">{does(resource)}</div>
        </div>

        <Tooltip label={told(resource)}>
          <span
            className="rcard-state"
            data-busy={state.busy}
            data-quiet={state.said === null}
            role="img"
            aria-label={state.said ?? told(resource)}
          >
            {state.said}
          </span>
        </Tooltip>
      </div>

      {shelf === 'storage' && (
        <div className="rcard-figure">
          <span className="rcard-count">
            {resource.itemsCount.toLocaleString()}
          </span>
          <span className="rcard-unit">
            {resource.itemsCount === 1 ? 'item' : 'items'}
          </span>
          {resource.personal && (
            <span className="rcard-role" data-plain="true">
              <IconLock size={12} /> Only you
            </span>
          )}
        </div>
      )}

      {lines.length > 0 && (
        <ul className="rcard-lines">
          {lines.map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
      )}

      {problem && <div className="rcard-error">{problem}</div>}

      {machine?.warnings.map((said) => (
        <div key={said} className="rcard-notice">
          {said}
        </div>
      ))}

      {resource.emptiedAt && (
        <div className="rcard-error">
          The sync {ago(resource.emptiedAt)} found nothing here, so its items
          stay until a sync finds files again
        </div>
      )}

      <footer className="rcard-foot">
        <button
          type="button"
          className="rcard-more"
          aria-expanded={open}
          onClick={() => setOpen((held) => !held)}
        >
          Details
          <IconChevronDown size={14} stroke={1.8} data-open={open} />
        </button>

        {resource.archivedAt ? (
          <div className="rcard-actions" hidden={!resource.manageable}>
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
          </div>
        ) : (
          <div className="rcard-actions">
            {unlinked && (
              <Button
                size="compact-sm"
                radius="xl"
                color="brand"
                leftSection={<IconLink size={14} />}
                onClick={() => acts.relink(resource)}
              >
                Get a fresh code
              </Button>
            )}

            {resource.manageable &&
              resource.delegated &&
              resource.connectUrl && (
                <Button
                  component="a"
                  href={resource.connectUrl}
                  size="compact-sm"
                  radius="xl"
                  color={resource.needsConnect ? 'brand' : 'gray'}
                  variant={resource.needsConnect ? 'filled' : 'subtle'}
                  leftSection={<IconPlugConnected size={14} />}
                >
                  {resource.needsConnect
                    ? resource.connectedBy
                      ? 'Reconnect'
                      : 'Connect'
                    : 'Connect again'}
                </Button>
              )}

            {resource.syncable && (
              <Tooltip label="Sync now">
                <ActionIcon
                  size={32}
                  radius="xl"
                  variant="default"
                  aria-label={`Sync ${resource.key}`}
                  loading={resource.syncing}
                  onClick={() => acts.sync(resource)}
                >
                  <IconRefresh size={16} stroke={1.8} />
                </ActionIcon>
              </Tooltip>
            )}

            <Menu position="bottom-end" width={220}>
              <Menu.Target>
                <ActionIcon
                  size={32}
                  radius="xl"
                  variant="subtle"
                  color="gray"
                  aria-label={`More for ${resource.key}`}
                >
                  <IconDots size={16} stroke={1.8} />
                </ActionIcon>
              </Menu.Target>
              <Menu.Dropdown>
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
                {resource.manageable && (
                  <>
                    {linkable && !unlinked && (
                      <Menu.Item
                        leftSection={<IconLink size={15} />}
                        onClick={() => acts.relink(resource)}
                      >
                        Link up again
                      </Menu.Item>
                    )}
                    {administrator &&
                      resource.capabilities.includes('storage') && (
                        <Menu.Item
                          disabled={resource.defaultStorage}
                          leftSection={<IconStar size={15} />}
                          onClick={() => acts.takeDrops(resource)}
                        >
                          Take drops
                        </Menu.Item>
                      )}
                    {administrator &&
                      resource.capabilities.includes('inference') && (
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
          </div>
        )}
      </footer>

      {open && <Details resource={resource} acts={acts} />}
    </article>
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
      <span className="rcard-when">
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
          className="rcard-when rcard-every"
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
