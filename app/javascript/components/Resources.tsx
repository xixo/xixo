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
  IconClock,
  IconDots,
  IconLock,
  IconPencil,
  IconPlugConnected,
  IconPlus,
  IconRefresh,
  IconSparkles,
  IconStar,
  IconStarFilled,
} from '@tabler/icons-react'
import {
  ArchiveResourceDocument,
  CheckResourceDocument,
  ResourcesDocument,
  SetDefaultInferenceDocument,
  SetDefaultStorageDocument,
  SetSyncIntervalDocument,
  SyncResourceDocument,
} from '@uris-to/client'
import { useQuery } from '@uris-to/client/react'
import {
  type CSSProperties,
  type RefObject,
  useEffect,
  useRef,
  useState,
} from 'react'
import { useParams } from 'react-router-dom'
import { useTitle } from '../hooks/useTitle'
import { ago, dated } from '../when'
import { Attach, type Editing, glyphFor } from './Attach'
import { useAloud, useSay } from './Say'
import { Intro } from './Settings'

interface Resource {
  id: string
  type: string
  key: string
  name?: string | null
  healthy: boolean
  checkedAt?: string | null
  checkError?: string | null
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
  personal: boolean
  delegated: boolean
  needsConnect: boolean
  connectedBy?: string | null
  connectUrl?: string | null
  via?: string | null
}

function toneFor(resource: Resource) {
  if (resource.syncing) return 'var(--busy)'
  if (resource.needsConnect) return 'var(--bad)'
  if (!resource.checkedAt) return 'var(--edge)'

  return resource.healthy ? 'var(--ok)' : 'var(--bad)'
}

function standing(resource: Resource) {
  if (resource.syncing) return 'syncing'
  if (resource.needsConnect)
    return resource.connectedBy ? 'needs reconnecting' : 'not connected yet'
  if (!resource.checkedAt) return 'never checked'

  return resource.healthy ? 'reachable' : 'failing'
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
  const [attaching, setAttaching] = useState(false)
  const [editing, setEditing] = useState<Editing | null>(null)
  const arrived = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (landed) arrived.current?.scrollIntoView({ block: 'center' })
  }, [landed])

  if (loading && !data) return <Loader size="sm" color="var(--brass)" />
  if (error) return <Alert color="red">{error.message}</Alert>

  const resources = (data?.resources ?? []) as Resource[]
  const transports = resources
    .filter((resource) => resource.capabilities.includes('transport'))
    .map((resource) => resource.key)
  const shelves = SHELVES.map((shelf) => ({
    ...shelf,
    held: resources.filter((resource) => shelfOf(resource) === shelf.key),
  })).filter((shelf) => shelf.held.length > 0)

  const acts: Acts = {
    check: async (resource) => {
      const answered = await check.execute({ id: resource.id })

      if (!answered) return

      say(
        answered.checkResource?.ok
          ? { text: `${resource.key} answers.` }
          : {
              text:
                answered.checkResource?.resource.checkError ??
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
    putAway,
  }

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
            : 'The places your items live, the models that read them, and the tools agents reach for.'
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
            color="chalk"
            leftSection={<IconPlus size={16} stroke={2} />}
            onClick={() => setAttaching(true)}
          >
            Attach
          </Button>
        )}
      </Intro>

      {attaching && (
        <Attach
          opened
          transports={transports}
          onClose={() => setAttaching(false)}
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

      {shelves.map((shelf) => (
        <section key={shelf.key} className="shelf-group">
          <div className="shelf-group-head">
            <h2 className="label">{shelf.title}</h2>
            <span className="shelf-group-note">{shelf.note}</span>
          </div>

          <div className="rcards" data-compact={shelf.key === 'tools'}>
            {shelf.held.map((resource) => (
              <ResourceCard
                key={resource.id}
                resource={resource}
                landed={resource.id === landed}
                landedRef={resource.id === landed ? arrived : undefined}
                putting={putting === resource.id}
                acts={acts}
              />
            ))}
          </div>
        </section>
      ))}

      {resources.length === 0 && (
        <div className="settings-empty">
          {shelved
            ? 'Nothing has been put away. A resource you stop using goes here rather than being deleted, and what it catalogued stays searchable.'
            : 'No resources are attached yet. Attach one and its contents become items you can search.'}
        </div>
      )}
    </div>
  )
}

interface Acts {
  check: (resource: Resource) => void
  sync: (resource: Resource) => void
  takeDrops: (resource: Resource) => void
  takeQuestions: (resource: Resource) => void
  schedule: (resource: Resource, seconds: number | null) => Promise<boolean>
  change: (resource: Resource) => void
  putAway: (resource: Resource, archived: boolean) => void
}

const SHELVES = [
  {
    key: 'storage',
    title: 'Storage',
    note: 'Where your items live',
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
    key: 'networks',
    title: 'Networks',
    note: 'What uris reaches the others through',
    tone: 'var(--k-email)',
  },
] as const

type Shelf = (typeof SHELVES)[number]['key']

function shelfOf(resource: Resource): Shelf {
  if (resource.capabilities.includes('storage')) return 'storage'
  if (resource.capabilities.includes('inference')) return 'models'
  if (resource.capabilities.includes('transport')) return 'networks'

  return 'tools'
}

function ResourceCard({
  resource,
  landed,
  landedRef,
  putting,
  acts,
}: {
  resource: Resource
  landed: boolean
  landedRef?: RefObject<HTMLElement | null>
  putting: boolean
  acts: Acts
}) {
  const Glyph = glyphFor(resource.type)
  const shelf = shelfOf(resource)
  const tone = SHELVES.find((held) => held.key === shelf)?.tone
  const storage = shelf === 'storage'

  return (
    <article
      ref={landedRef}
      className="rcard"
      data-landed={landed}
      data-failing={Boolean(resource.checkError || resource.needsConnect)}
      style={{ '--tone': tone, '--state': toneFor(resource) } as CSSProperties}
    >
      <div className="rcard-top">
        <span className="rcard-icon">
          <Glyph size={20} stroke={1.6} />
        </span>

        <Tooltip
          label={
            resource.checkError ??
            (resource.checkedAt
              ? `checked ${ago(resource.checkedAt)}`
              : 'not checked yet')
          }
        >
          <span className="rcard-state" data-busy={resource.syncing}>
            {standing(resource)}
          </span>
        </Tooltip>
      </div>

      <div className="rcard-name">
        <h3 className="rcard-key">{resource.key}</h3>
        <div className="rcard-kind">
          {resource.name && resource.name !== resource.key && (
            <>{resource.name} · </>
          )}
          <span className="mono">{resource.type}</span>
          {resource.via && (
            <>
              {' '}
              · via <span className="mono">{resource.via}</span>
            </>
          )}
        </div>
      </div>

      {storage && (
        <div className="rcard-figure">
          <span className="rcard-count">
            {resource.itemsCount.toLocaleString()}
          </span>
          <span className="rcard-unit">
            {resource.itemsCount === 1 ? 'item' : 'items'}
          </span>
        </div>
      )}

      {(resource.defaultStorage ||
        resource.defaultInference ||
        resource.personal) && (
        <div className="rcard-roles">
          {resource.defaultStorage && (
            <span className="rcard-role">
              <IconStarFilled size={12} /> Drops land here
            </span>
          )}
          {resource.defaultInference && (
            <span className="rcard-role">
              <IconSparkles size={12} /> Answers questions
            </span>
          )}
          {resource.personal && (
            <span className="rcard-role" data-plain="true">
              <IconLock size={12} /> Only you
            </span>
          )}
        </div>
      )}

      {resource.checkError && (
        <div className="rcard-error">{resource.checkError}</div>
      )}

      <footer className="rcard-foot">
        {resource.archivedAt ? (
          <>
            <span className="rcard-when">
              put away {dated(resource.archivedAt)}
            </span>
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
        ) : (
          <>
            {resource.syncable ? (
              <Every resource={resource} onKeep={acts.schedule} />
            ) : (
              <span className="rcard-when">
                {resource.capabilities.join(' · ')}
              </span>
            )}

            <div className="rcard-actions">
              {resource.delegated && resource.connectUrl && (
                <Button
                  component="a"
                  href={resource.connectUrl}
                  size="compact-sm"
                  radius="xl"
                  color={resource.needsConnect ? 'chalk' : 'gray'}
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
                  {resource.capabilities.includes('storage') && (
                    <Menu.Item
                      disabled={resource.defaultStorage}
                      leftSection={<IconStar size={15} />}
                      onClick={() => acts.takeDrops(resource)}
                    >
                      Take drops
                    </Menu.Item>
                  )}
                  {resource.capabilities.includes('inference') && (
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
                </Menu.Dropdown>
              </Menu>
            </div>
          </>
        )}
      </footer>
    </article>
  )
}

function Every({
  resource,
  onKeep,
}: {
  resource: Resource
  onKeep: (resource: Resource, seconds: number | null) => Promise<boolean>
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
            <Button type="submit" color="chalk" loading={busy}>
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
