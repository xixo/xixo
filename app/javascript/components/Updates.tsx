import { Button, Group, Loader, Stack } from '@mantine/core'
import { useState } from 'react'
import {
  LinkUpdatesDocument,
  type LinkUpdatesQuery,
  RequestMachineUpdateDocument,
  RequestServerUpdateDocument,
  ServerUpdatesDocument,
} from 'xixo'
import { useQuery } from 'xixo/react'
import { useTitle } from '../hooks/useTitle'
import { ago, dated } from '../when'
import { Failed } from './Failed'
import { useAloud } from './Say'
import { Intro } from './Settings'
import { Sure } from './Sure'

const CHANNELS = [
  { value: 'releases', label: 'Releases' },
  { value: 'main', label: 'main' },
]

const DONE: Record<string, string> = {
  check: 'Checked for updates',
  pull: 'Pulled',
  swap: 'Updated',
  watch: 'Watched the update',
  rollback: 'Rolled back',
  refuse: 'Refused',
  request: 'Ignored a request',
  update_now: 'Asked to update now',
  pause: 'Paused updates',
  resume: 'Resumed updates',
  roll_back: 'Asked to roll back',
  channel: 'Chose a channel',
}

const PLATFORMS: Record<string, string> = { linux: 'Linux', darwin: 'Mac' }

type LinkUpdates = NonNullable<LinkUpdatesQuery['linkUpdates']>
type Rollout = NonNullable<LinkUpdates['rollout']>
type Machine = LinkUpdates['machines'][number]

const short = (digest?: string | null) =>
  digest ? digest.replace('sha256:', '').slice(0, 12) : ''

const minutes = (seconds: number) => `${Math.round(seconds / 60)} minutes`

const since = (at: string) => {
  const passed = Math.round((Date.now() - new Date(at).getTime()) / 1000)
  if (passed < 60) return 'less than a minute'
  if (passed < 3600) return `${Math.floor(passed / 60)} minutes`
  if (passed < 86400) return `${Math.floor(passed / 3600)} hours`
  return `${Math.floor(passed / 86400)} days`
}

export function rolloutSaid(rollout: Rollout) {
  const version = rollout.version ?? 'the release'

  switch (rollout.phase) {
    case 'waiting_for_server':
      return `The server has run ${version} for ${since(rollout.startedAt)}. The first machines update once it has been healthy for ${minutes(rollout.serverHealthyFor)}.`
    case 'first':
      return rollout.firstMachines
        .map(({ os, resource, arrivedAt }) => {
          const platform = PLATFORMS[os] ?? os
          if (!resource) return `No ${platform} machine can go first.`
          if (arrivedAt)
            return `${resource.name} has been on ${version} for ${since(arrivedAt)}.`
          return `Waiting for ${resource.name} to update, the first ${platform}.`
        })
        .concat(
          `Everyone follows once the first machines have stayed connected for ${minutes(rollout.firstHealthyFor)}.`,
        )
        .join(' ')
    case 'everyone':
      return `Every machine is offered ${version}.`
    case 'done':
      return `Every machine is on ${version}.`
    case 'held':
      return `Stopped: ${rollout.heldReason ?? 'a first machine went back'}.`
    case 'paused':
      return 'Machine updates are paused.'
  }

  return ''
}

export function machineSaid(
  machine: NonNullable<Machine['machine']>,
  release?: string | null,
) {
  const running = machine.version ? `xixo link ${machine.version}` : 'xixo link'
  const target =
    release && release !== machine.version ? release : 'the release xixo ships'

  switch (machine.updateState) {
    case 'server':
      return `${running}, updated with the server`
    case 'offline':
      return machine.seenAt
        ? `${running}, offline since ${ago(machine.seenAt)}`
        : `${running}, offline`
    case 'manual':
      return `${running}. Run the link-up command again so it updates itself`
    case 'paused':
      return `${running}, updates paused`
    case 'ahead':
      return `${running}, newer than xixo allows, going back`
    case 'waiting_for_xixo':
      return `${running}, newer than xixo allows. Waiting for xixo to catch up`
    case 'current':
      return `${running}, up to date`
    case 'updating':
      return `${running}, updating to ${target}`
    case 'held':
      return `${running}, held at this version while the rollout is stopped`
    case 'waiting':
      return `${running}, waiting for the rollout`
  }

  return running
}

export function Updates() {
  useTitle('Updates')

  const { data, loading, error, refetch } = useQuery(ServerUpdatesDocument)
  const links = useQuery(LinkUpdatesDocument)
  const ask = useAloud(
    RequestServerUpdateDocument,
    'The updater did not take that.',
  )
  const [rolling, setRolling] = useState(false)

  const updates = data?.serverUpdates
  const linked = links.data?.linkUpdates
  const failed = error ?? links.error

  const request = async (action: string, channel?: string) => {
    await ask.execute({ action, channel })
    setTimeout(refetch, 6000)
    refetch()
  }

  return (
    <div className="settings-page">
      <Intro
        title="Updates"
        lead="xixo keeps this server, and xixo link on every machine, on the builds xixo's CI built and signed."
      />

      {failed && (
        <Failed
          error={failed}
          retry={() => {
            refetch()
            links.refetch()
          }}
        />
      )}
      {(loading || links.loading) && !data && !links.data && (
        <Loader size="sm" color="var(--accent)" />
      )}

      {links.data && !linked && (
        <p className="settings-lead">Only an administrator sees updates.</p>
      )}

      {linked && (
        <Machines
          linked={linked}
          refetch={() => {
            links.refetch()
          }}
        />
      )}

      {data && !updates && linked && (
        <p className="settings-lead">
          This server's updates are run by its operator.
        </p>
      )}

      {updates?.manual && (
        <div className="panel">
          <div className="setting">
            <div>
              <div className="setting-name">
                Updates are manual on this server
              </div>
              <div className="setting-note">
                No updater reports to it. The self-hosting guide sets one up.
              </div>
            </div>
          </div>
        </div>
      )}

      {updates && !updates.manual && (
        <Stack gap="var(--s5)">
          <Stack gap="var(--s3)">
            {linked && <h2 className="section-title">Server</h2>}
            <div className="panel">
              <div className="setting">
                <div>
                  <div className="setting-name">
                    {updates.paused
                      ? 'Updates are paused'
                      : `Following ${updates.channel === 'main' ? 'every push to main' : 'releases'}`}
                  </div>
                  <div className="setting-note">
                    {updates.checkedAt
                      ? `Checked ${ago(updates.checkedAt)}.`
                      : 'Not checked yet.'}
                  </div>
                </div>

                <Group gap="var(--s2)" wrap="nowrap">
                  <Button
                    size="xs"
                    radius="xl"
                    variant="default"
                    loading={ask.loading}
                    onClick={() => request(updates.paused ? 'resume' : 'pause')}
                  >
                    {updates.paused ? 'Resume updates' : 'Pause updates'}
                  </Button>
                  <Button
                    size="xs"
                    radius="xl"
                    color="brand"
                    loading={ask.loading}
                    disabled={updates.paused}
                    onClick={() => request('update_now')}
                  >
                    Update now
                  </Button>
                </Group>
              </div>

              <div className="setting">
                <div>
                  <div className="setting-name">Channel</div>
                  <div className="setting-note">
                    Releases follow the highest version. main follows every push
                    that passes CI.
                  </div>
                </div>

                <div className="switcher" data-wide="true">
                  {CHANNELS.map(({ value, label }) => (
                    <button
                      key={value}
                      type="button"
                      data-on={updates.channel === value}
                      aria-pressed={updates.channel === value}
                      onClick={() => request('channel', value)}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </div>

              {updates.migrationNote && (
                <div className="setting">
                  <div>
                    <div className="setting-name">Database</div>
                    <div className="setting-note">{updates.migrationNote}</div>
                  </div>
                </div>
              )}

              <div className="setting">
                <div>
                  <div className="setting-name">Roll back</div>
                  <div className="setting-note">
                    Puts every image back on the build before, and skips the
                    build it leaves until a newer one comes.
                  </div>
                </div>

                <Button
                  size="xs"
                  radius="xl"
                  variant="default"
                  color="red"
                  disabled={!updates.images.some((image) => image.previous)}
                  onClick={() => setRolling(true)}
                >
                  Roll back
                </Button>
              </div>
            </div>
          </Stack>

          <Stack gap="var(--s3)">
            <h2 className="section-title">What runs</h2>
            <div className="panel">
              {updates.images.map((image) => {
                const stale = image.containers.filter((held) => held.stale)

                return (
                  <div className="setting" key={image.name}>
                    <div>
                      <div className="setting-name">{image.name}</div>
                      <div className="setting-note">
                        {image.revision
                          ? `Commit ${image.revision.slice(0, 8)}`
                          : short(image.current) || 'No build yet'}
                        {image.created && `, built ${dated(image.created)}`}
                        {image.containers.length > 0 &&
                          ` · ${image.containers
                            .map(
                              (held) =>
                                `${held.service ?? held.name} ${held.health ?? held.state}`,
                            )
                            .join(', ')}`}
                      </div>
                    </div>

                    <div className="setting-note">
                      {image.target
                        ? `Updating to ${short(image.target)}`
                        : stale.length > 0
                          ? `${stale.length} on an older build`
                          : 'Up to date'}
                    </div>
                  </div>
                )
              })}
            </div>
          </Stack>

          {updates.events.length > 0 && (
            <Stack gap="var(--s3)">
              <h2 className="section-title">Recent</h2>
              <div className="panel">
                {updates.events.map((event) => (
                  <div className="setting" key={`${event.at}-${event.action}`}>
                    <div>
                      <div className="setting-name">
                        {DONE[event.action] ?? event.action}
                        {event.kind && ` ${event.kind}`}
                        {event.channel && ` ${event.channel}`}
                        {event.by && `, by ${event.by}`}
                      </div>
                      {event.error && (
                        <div className="setting-note">{event.error}</div>
                      )}
                    </div>
                    <div className="setting-note">{dated(event.at)}</div>
                  </div>
                ))}
              </div>
            </Stack>
          )}
        </Stack>
      )}

      <Sure
        opened={rolling}
        onClose={() => setRolling(false)}
        onSure={async () => {
          setRolling(false)
          await request('roll_back')
        }}
        title="Roll back this server?"
        verb="Roll back"
        loading={ask.loading}
      >
        Every image goes back to the build before it.{' '}
        {updates?.rollbackNote ??
          'A rollback does not undo a migration, so the build before runs against the newer database.'}
      </Sure>
    </div>
  )
}

function Machines({
  linked,
  refetch,
}: {
  linked: LinkUpdates
  refetch: () => void
}) {
  const ask = useAloud(
    RequestMachineUpdateDocument,
    'xixo could not steer that update.',
  )
  const [backing, setBacking] = useState<Machine | null>(null)
  const rollout = linked.rollout
  const paused = rollout?.phase === 'paused'

  const request = async (action: string, id?: string) => {
    await ask.execute({ id, action })
    refetch()
  }

  return (
    <Stack gap="var(--s3)">
      <h2 className="section-title">Machines</h2>
      <div className="panel">
        <div className="setting">
          <div>
            <div className="setting-name">
              {linked.release
                ? `xixo ships xixo link ${linked.release}`
                : 'xixo ships no xixo link'}
            </div>
            <div className="setting-note">
              {rollout
                ? rolloutSaid(rollout)
                : 'This xixo carries no signed release description, so every machine is offered the build at once.'}
            </div>
          </div>

          {rollout && (
            <Button
              size="xs"
              radius="xl"
              variant="default"
              loading={ask.loading}
              onClick={() => request(paused ? 'resume' : 'pause')}
            >
              {paused ? 'Resume machine updates' : 'Pause machine updates'}
            </Button>
          )}
        </div>

        {linked.machines.map((resource) => {
          const machine = resource.machine
          if (!machine) return null

          const state = machine.updateState
          const steerable =
            machine.connected &&
            machine.updatesItself &&
            state !== 'server' &&
            state !== 'manual'
          const canGoFirst =
            steerable &&
            state === 'waiting' &&
            (rollout?.phase === 'waiting_for_server' ||
              rollout?.phase === 'first')

          return (
            <div className="setting" key={resource.id}>
              <div>
                <div className="setting-name">{resource.name}</div>
                <div className="setting-note">
                  {machineSaid(machine, linked.release)}
                  {machine.lastUpdatedAt &&
                    `. Updated ${ago(machine.lastUpdatedAt)}`}
                  {machine.lastRollback && (
                    <>
                      <br />
                      {machine.lastRollback}
                      {machine.lastRollbackAt &&
                        `, ${ago(machine.lastRollbackAt)}`}
                    </>
                  )}
                </div>
              </div>

              {steerable && (
                <Group gap="var(--s2)" wrap="wrap" justify="flex-end">
                  <Button
                    size="xs"
                    radius="xl"
                    variant="default"
                    loading={ask.loading}
                    onClick={() =>
                      request(
                        state === 'paused' ? 'resume' : 'pause',
                        resource.id,
                      )
                    }
                  >
                    {state === 'paused' ? 'Resume' : 'Pause'}
                  </Button>
                  {canGoFirst && (
                    <Button
                      size="xs"
                      radius="xl"
                      variant="default"
                      loading={ask.loading}
                      onClick={() => request('first', resource.id)}
                    >
                      Go first
                    </Button>
                  )}
                  {(state === 'waiting' ||
                    state === 'held' ||
                    state === 'updating') && (
                    <Button
                      size="xs"
                      radius="xl"
                      color="brand"
                      loading={ask.loading}
                      onClick={() => request('update_now', resource.id)}
                    >
                      Update now
                    </Button>
                  )}
                  <Button
                    size="xs"
                    radius="xl"
                    variant="default"
                    color="red"
                    onClick={() => setBacking(resource)}
                  >
                    Roll back
                  </Button>
                </Group>
              )}
            </div>
          )
        })}
      </div>

      <Sure
        opened={backing !== null}
        onClose={() => setBacking(null)}
        onSure={async () => {
          const held = backing
          setBacking(null)
          if (held) await request('roll_back', held.id)
        }}
        title={`Roll back ${backing?.name ?? 'this machine'}?`}
        verb="Roll back"
        loading={ask.loading}
      >
        xixo link on the machine goes back to the release before, which it still
        holds. xixo offers the current release again at its next rollout.
      </Sure>
    </Stack>
  )
}
