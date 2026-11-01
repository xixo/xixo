import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Updates } from '../../app/javascript/components/Updates'
import { fakeClient, show } from './support/screen'

const reported = (overrides: Record<string, unknown> = {}) => ({
  manual: false,
  channel: 'main',
  paused: false,
  checkedAt: new Date(Date.now() - 3 * 60_000).toISOString(),
  images: [
    {
      name: 'xixo',
      current: `sha256:${'a'.repeat(64)}`,
      previous: `sha256:${'b'.repeat(64)}`,
      created: new Date(Date.now() - 2 * 3600_000).toISOString(),
      revision: 'c589ffe682d3497df159d3615be691387ebea7d9',
      version: 'main',
      target: null,
      containers: [
        {
          name: 'xixo-xixo-1',
          service: 'xixo',
          state: 'running',
          health: 'healthy',
          stale: false,
        },
      ],
    },
    {
      name: 'xixo-link',
      current: `sha256:${'c'.repeat(64)}`,
      previous: null,
      created: null,
      revision: null,
      version: null,
      target: `sha256:${'d'.repeat(64)}`,
      containers: [],
    },
  ],
  events: [
    {
      at: new Date(Date.now() - 60_000).toISOString(),
      action: 'refuse',
      kind: 'xixo',
      digest: null,
      error: 'carries no attestation from xixo/xixo',
      by: null,
      channel: null,
    },
  ],
  ...overrides,
})

const machine = (overrides: Record<string, unknown> = {}) => ({
  hostname: 'studio',
  os: 'darwin',
  version: '0.4.0',
  release: '0.5.0',
  serial: 40,
  protocol: 1,
  current: false,
  updates: true,
  updatesItself: true,
  connected: true,
  seenAt: new Date().toISOString(),
  updateState: 'waiting',
  lastUpdatedAt: null,
  lastRollback: null,
  lastRollbackAt: null,
  ...overrides,
})

const linked = (overrides: Record<string, unknown> = {}) => ({
  release: '0.5.0',
  protocol: 1,
  rollout: {
    release: 'f'.repeat(64),
    version: '0.5.0',
    serial: 50,
    phase: 'first',
    startedAt: new Date(Date.now() - 40 * 60_000).toISOString(),
    phaseAt: new Date(Date.now() - 20 * 60_000).toISOString(),
    heldReason: null,
    serverHealthyFor: 900,
    firstHealthyFor: 1800,
    firstMachines: [
      {
        os: 'linux',
        arrivedAt: new Date(Date.now() - 12 * 60_000).toISOString(),
        picked: false,
        resource: { id: '3', key: 'box', name: 'Box' },
      },
      {
        os: 'darwin',
        arrivedAt: null,
        picked: true,
        resource: { id: '7', key: 'studio', name: 'Studio' },
      },
    ],
  },
  machines: [
    {
      id: '1',
      key: 'local',
      name: 'Hub',
      machine: machine({
        hostname: 'xixo',
        os: 'linux',
        version: '0.5.0',
        current: true,
        updatesItself: false,
        updateState: 'server',
      }),
    },
    {
      id: '3',
      key: 'box',
      name: 'Box',
      machine: machine({
        hostname: 'box',
        os: 'linux',
        version: '0.5.0',
        current: true,
        updateState: 'current',
        lastUpdatedAt: new Date(Date.now() - 12 * 60_000).toISOString(),
      }),
    },
    {
      id: '7',
      key: 'studio',
      name: 'Studio',
      machine: machine({ updateState: 'updating' }),
    },
    {
      id: '9',
      key: 'attic',
      name: 'Attic',
      machine: machine({
        hostname: 'attic',
        os: 'linux',
        version: '0.3.0',
        updateState: 'waiting',
        lastRollback: 'xixo link could not update to 0.4.0: it did not connect',
        lastRollbackAt: new Date(Date.now() - 3 * 86_400_000).toISOString(),
      }),
    },
  ],
  ...overrides,
})

function updates(serverUpdates: unknown, linkUpdates: unknown = null) {
  const { client, asked } = fakeClient({
    ServerUpdates: () => ({ serverUpdates }),
    LinkUpdates: () => ({ administrator: true, linkUpdates }),
    RequestServerUpdate: () => ({
      requestServerUpdate: { serverUpdates: { manual: false } },
    }),
    RequestMachineUpdate: () => ({
      requestMachineUpdate: { linkUpdates: { protocol: 1 } },
    }),
  })

  show(<Updates />, client)

  return asked
}

const requests = (asked: { name: string; variables: unknown }[]) =>
  asked
    .filter((ask) => ask.name === 'RequestServerUpdate')
    .map((ask) => ask.variables)

describe('server updates', () => {
  test('the page says what each image runs and what the updater did', async () => {
    updates(reported())

    expect(await screen.findByText('Following every push to main')).toBeTruthy()
    expect(screen.getByText('Checked 3m ago.')).toBeTruthy()
    expect(
      screen.getByText(/Commit c589ffe6, built 2h ago · xixo healthy/),
    ).toBeTruthy()
    expect(screen.getByText('Up to date')).toBeTruthy()
    expect(screen.getByText(`Updating to ${'d'.repeat(12)}`)).toBeTruthy()
    expect(screen.getByText('Refused xixo')).toBeTruthy()
    expect(
      screen.getByText('carries no attestation from xixo/xixo'),
    ).toBeTruthy()
  })

  test('update now, pause, and a channel choice are asked of the updater', async () => {
    const asked = updates(reported())

    await userEvent.click(
      await screen.findByRole('button', { name: 'Update now' }),
    )
    await userEvent.click(screen.getByRole('button', { name: 'Pause updates' }))
    await userEvent.click(screen.getByRole('button', { name: 'Releases' }))

    expect(requests(asked)).toEqual([
      { action: 'update_now', channel: undefined },
      { action: 'pause', channel: undefined },
      { action: 'channel', channel: 'releases' },
    ])
  })

  test('a rollback asks first', async () => {
    const asked = updates(reported())

    await userEvent.click(
      await screen.findByRole('button', { name: 'Roll back' }),
    )
    expect(requests(asked)).toEqual([])

    expect(
      await screen.findByText(/A rollback does not undo a migration/),
    ).toBeTruthy()
    const buttons = screen.getAllByRole('button', { name: 'Roll back' })
    await userEvent.click(buttons[buttons.length - 1])

    expect(requests(asked)).toEqual([
      { action: 'roll_back', channel: undefined },
    ])
  })

  test('a paused server offers resume and no update now', async () => {
    updates(reported({ paused: true }))

    expect(await screen.findByText('Updates are paused')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Resume updates' })).toBeTruthy()
    expect(
      screen
        .getByRole('button', { name: 'Update now' })
        .hasAttribute('disabled'),
    ).toBe(true)
  })

  test('a server with no updater says its updates are manual', async () => {
    updates(reported({ manual: true, images: [], events: [] }))

    expect(
      await screen.findByText('Updates are manual on this server'),
    ).toBeTruthy()
  })
})

const machineRequests = (asked: { name: string; variables: unknown }[]) =>
  asked
    .filter((ask) => ask.name === 'RequestMachineUpdate')
    .map((ask) => ask.variables)

describe('machine updates', () => {
  test('the page says where the rollout is and where each machine stands', async () => {
    updates(null, linked())

    expect(await screen.findByText('xixo ships xixo link 0.5.0')).toBeTruthy()
    expect(
      screen.getByText(
        'Box has been on 0.5.0 for 12 minutes. Waiting for Studio to update, the first Mac. Everyone follows once the first machines have stayed connected for 30 minutes.',
      ),
    ).toBeTruthy()
    expect(
      screen.getByText('xixo link 0.5.0, updated with the server'),
    ).toBeTruthy()
    expect(
      screen.getByText('xixo link 0.5.0, up to date. Updated 12m ago'),
    ).toBeTruthy()
    expect(screen.getByText('xixo link 0.4.0, updating to 0.5.0')).toBeTruthy()
    expect(
      screen.getByText(/xixo link 0\.3\.0, waiting for the rollout/),
    ).toBeTruthy()
    expect(
      screen.getByText(
        /could not update to 0\.4\.0: it did not connect, 3d ago/,
      ),
    ).toBeTruthy()
    expect(
      screen.getByText("This server's updates are run by its operator."),
    ).toBeTruthy()
  })

  test('an administrator steers a machine and the rollout', async () => {
    const asked = updates(null, linked())

    await screen.findByText('xixo ships xixo link 0.5.0')
    const buttons = screen.getAllByRole('button', { name: 'Update now' })
    await userEvent.click(buttons[0])
    await userEvent.click(screen.getByRole('button', { name: 'Go first' }))
    await userEvent.click(
      screen.getByRole('button', { name: 'Pause machine updates' }),
    )

    expect(machineRequests(asked)).toEqual([
      { id: '7', action: 'update_now' },
      { id: '9', action: 'first' },
      { id: undefined, action: 'pause' },
    ])
  })

  test('rolling a machine back asks first', async () => {
    const asked = updates(null, linked())

    await screen.findByText('xixo ships xixo link 0.5.0')
    await userEvent.click(
      screen.getAllByRole('button', { name: 'Roll back' })[0],
    )
    expect(machineRequests(asked)).toEqual([])

    expect(await screen.findByText('Roll back Box?')).toBeTruthy()
    const buttons = screen.getAllByRole('button', { name: 'Roll back' })
    await userEvent.click(buttons[buttons.length - 1])

    expect(machineRequests(asked)).toEqual([{ id: '3', action: 'roll_back' }])
  })

  test('a held rollout says why, and a paused one offers resume', async () => {
    updates(
      null,
      linked({
        rollout: {
          ...linked().rollout,
          phase: 'held',
          heldReason: 'Box went back to 0.4.0: it did not connect',
        },
      }),
    )

    expect(
      await screen.findByText(
        'Stopped: Box went back to 0.4.0: it did not connect.',
      ),
    ).toBeTruthy()
  })

  test('someone who is not an administrator sees nothing', async () => {
    updates(null, null)

    expect(
      await screen.findByText('Only an administrator sees updates.'),
    ).toBeTruthy()
  })
})
