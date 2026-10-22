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

function updates(serverUpdates: unknown) {
  const { client, asked } = fakeClient({
    ServerUpdates: () => ({ serverUpdates }),
    RequestServerUpdate: () => ({
      requestServerUpdate: { serverUpdates: { manual: false } },
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
