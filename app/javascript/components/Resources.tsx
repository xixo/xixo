import {
  Alert,
  Button,
  Group,
  Loader,
  Menu,
  NumberInput,
  Stack,
  Text,
  Tooltip,
} from '@mantine/core'
import {
  IconArchive,
  IconArchiveOff,
  IconCheck,
  IconDots,
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
import { type CSSProperties, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useTitle } from '../hooks/useTitle'
import { Attach, type Editing } from './Attach'
import { useAloud, useSay } from './Say'

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

function schedule(resource: Resource) {
  if (!resource.syncable) return 'nothing to enumerate'
  if (!resource.syncInterval) return 'on demand only'

  const every = `every ${Math.round(resource.syncInterval / 60)} min`
  const next = resource.nextSyncAt
    ? new Date(resource.nextSyncAt).toLocaleTimeString()
    : '—'

  return `${every} · next ${next}`
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
  const [minutes, setMinutes] = useState<Record<string, number | string>>({})
  const [attaching, setAttaching] = useState(false)
  const [editing, setEditing] = useState<Editing | null>(null)
  const arrived = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (landed) arrived.current?.scrollIntoView({ block: 'center' })
  }, [landed])

  if (loading && !data) return <Loader size="sm" color="var(--brass)" />
  if (error) return <Alert color="red">{error.message}</Alert>

  const resources = (data?.resources ?? []) as Resource[]

  return (
    <Stack gap="var(--s5)">
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

      <Group justify="space-between" align="flex-end">
        <div className="eyebrow">
          {shelved
            ? 'Put away, and still holding everything they ever catalogued'
            : 'The places your items live, and what each one can be asked to do'}
        </div>

        <Group gap="var(--s2)">
          <button
            type="button"
            className="tag"
            data-dot="false"
            data-on={shelved}
            aria-pressed={shelved}
            style={{ cursor: 'pointer' }}
            onClick={() => setShelved(!shelved)}
          >
            {shelved ? 'In use' : 'Put away'}
          </button>

          {!shelved && (
            <Button
              leftSection={<IconPlus size={16} stroke={2} />}
              onClick={() => setAttaching(true)}
            >
              Attach one
            </Button>
          )}
        </Group>
      </Group>

      {attaching && (
        <Attach
          opened
          onClose={() => setAttaching(false)}
          onAttached={refetch}
        />
      )}

      {editing && (
        <Attach
          opened
          editing={editing}
          onClose={() => setEditing(null)}
          onAttached={refetch}
        />
      )}

      <div className="panel">
        {resources.map((resource) => (
          <div
            key={resource.id}
            ref={resource.id === landed ? arrived : undefined}
            className="resource"
            data-landed={resource.id === landed}
            style={{ '--tone': toneFor(resource) } as CSSProperties}
          >
            <div className="resource-main">
              <div className="resource-name">
                <span className="entry-title">{resource.key}</span>
                <span className="resource-type">{resource.type}</span>
                <Tooltip
                  label={
                    resource.checkError ??
                    (resource.checkedAt
                      ? `checked ${new Date(resource.checkedAt).toLocaleString()}`
                      : 'not checked yet')
                  }
                >
                  <span className="resource-state">{standing(resource)}</span>
                </Tooltip>
              </div>

              <div className="resource-facts">
                {resource.name ?? '—'} ·{' '}
                <span className="figure">
                  {resource.itemsCount.toLocaleString()}
                </span>{' '}
                items · {resource.capabilities.join(', ')}
              </div>

              {(resource.personal ||
                resource.defaultStorage ||
                resource.defaultInference) && (
                <div className="resource-roles">
                  {resource.personal && (
                    <span className="tag" data-dot="false">
                      only you
                    </span>
                  )}
                  {resource.defaultStorage && (
                    <span
                      className="tag"
                      style={{ '--tone': 'var(--brass)' } as CSSProperties}
                    >
                      drops land here
                    </span>
                  )}
                  {resource.defaultInference && (
                    <span
                      className="tag"
                      style={{ '--tone': 'var(--brass)' } as CSSProperties}
                    >
                      answers questions
                    </span>
                  )}
                </div>
              )}

              <div className="resource-when">
                {schedule(resource)}
                {resource.syncedAt &&
                  ` · last ${new Date(resource.syncedAt).toLocaleString()}`}
              </div>

              {resource.checkError && (
                <div className="resource-error">{resource.checkError}</div>
              )}
            </div>

            {resource.archivedAt ? (
              <div className="resource-actions">
                <Button
                  size="xs"
                  radius="xl"
                  variant="default"
                  leftSection={<IconArchiveOff size={14} />}
                  loading={putting === resource.id}
                  onClick={() => putAway(resource, false)}
                >
                  Put back
                </Button>
              </div>
            ) : (
              <div className="resource-actions">
                {resource.delegated && resource.connectUrl && (
                  <Button
                    component="a"
                    href={resource.connectUrl}
                    size="xs"
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
                <Button
                  size="xs"
                  radius="xl"
                  variant="default"
                  leftSection={<IconCheck size={14} />}
                  onClick={async () => {
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
                  }}
                >
                  Check
                </Button>
                {resource.syncable && (
                  <Button
                    size="xs"
                    radius="xl"
                    color="chalk"
                    leftSection={<IconRefresh size={14} />}
                    disabled={resource.syncing}
                    onClick={async () => {
                      const answered = await sync.execute({
                        id: resource.id,
                      })

                      if (!answered) return

                      say({ text: `${resource.key} is syncing.` })
                      refetch()
                    }}
                  >
                    Sync
                  </Button>
                )}

                <Menu position="bottom-end" width={220}>
                  <Menu.Target>
                    <Button
                      size="xs"
                      radius="xl"
                      variant="subtle"
                      color="gray"
                      px="var(--s2)"
                      aria-label={`More for ${resource.key}`}
                    >
                      <IconDots size={16} stroke={1.8} />
                    </Button>
                  </Menu.Target>
                  <Menu.Dropdown>
                    {resource.capabilities.includes('storage') && (
                      <Menu.Item
                        disabled={resource.defaultStorage}
                        leftSection={
                          resource.defaultStorage ? (
                            <IconStarFilled size={15} />
                          ) : (
                            <IconStar size={15} />
                          )
                        }
                        onClick={async () => {
                          const answered = await takeDrops.execute({
                            id: resource.id,
                          })

                          if (!answered) return

                          say({ text: `Drops land in ${resource.key} now.` })
                          refetch()
                        }}
                      >
                        Take drops
                      </Menu.Item>
                    )}
                    {resource.capabilities.includes('inference') && (
                      <Menu.Item
                        disabled={resource.defaultInference}
                        leftSection={<IconSparkles size={15} />}
                        onClick={async () => {
                          const answered = await takeQuestions.execute({
                            id: resource.id,
                          })

                          if (!answered) return

                          say({
                            text: `${resource.key} answers questions now.`,
                          })
                          refetch()
                        }}
                      >
                        Take questions
                      </Menu.Item>
                    )}
                    {resource.changeable && (
                      <Menu.Item
                        leftSection={<IconPencil size={15} />}
                        onClick={() => setEditing(resource)}
                      >
                        Change
                      </Menu.Item>
                    )}
                    <Menu.Item
                      leftSection={<IconArchive size={15} />}
                      onClick={() => putAway(resource, true)}
                    >
                      Put away
                    </Menu.Item>
                  </Menu.Dropdown>
                </Menu>
              </div>
            )}

            {resource.syncable && !resource.archivedAt && (
              <form
                className="resource-every"
                onSubmit={async (event) => {
                  event.preventDefault()

                  const value = Number(minutes[resource.id])
                  const seconds = value > 0 ? Math.round(value * 60) : null
                  const answered = await setInterval.execute({
                    id: resource.id,
                    seconds,
                  })

                  if (!answered) return

                  say({
                    text: seconds
                      ? `${resource.key} syncs every ${Math.round(seconds / 60)} minutes.`
                      : `${resource.key} syncs on demand only.`,
                  })
                  refetch()
                }}
              >
                <span>Sync every</span>
                <NumberInput
                  size="xs"
                  w={84}
                  min={1}
                  radius="xl"
                  hideControls
                  placeholder="—"
                  aria-label={`Minutes between syncs of ${resource.key}`}
                  value={
                    minutes[resource.id] ??
                    (resource.syncInterval ? resource.syncInterval / 60 : '')
                  }
                  onChange={(value) =>
                    setMinutes((current) => ({
                      ...current,
                      [resource.id]: value,
                    }))
                  }
                />
                <span>minutes</span>
                <Button
                  type="submit"
                  size="compact-xs"
                  radius="xl"
                  variant="subtle"
                  color="gray"
                >
                  Keep
                </Button>
              </form>
            )}
          </div>
        ))}
      </div>

      {resources.length === 0 && (
        <Text c="dimmed" size="sm" maw="58ch">
          {shelved
            ? 'Nothing has been put away. A resource you stop using goes here rather than being deleted, and what it catalogued stays searchable.'
            : 'No resources are attached yet. Attach one and its contents become items you can search.'}
        </Text>
      )}
    </Stack>
  )
}
