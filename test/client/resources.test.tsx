import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Resources } from '../../app/javascript/components/Resources'
import { fakeClient, show } from './support/screen'

const resource = (overrides: Record<string, unknown>) => ({
  id: '1',
  type: 'database',
  key: 'household',
  name: 'Household',
  capabilities: ['storage'],
  itemsCount: 4,
  defaultStorage: true,
  defaultInference: false,
  syncInterval: null,
  nextSyncAt: null,
  syncedAt: null,
  syncing: false,
  syncable: false,
  checkedAt: null,
  checkError: null,
  healthy: true,
  checking: false,
  offline: false,
  offlineHost: null,
  offlineLastSeenAt: null,
  emptiedAt: null,
  archivedAt: null,
  settings: {},
  heldCredentials: [],
  changeable: true,
  manageable: false,
  personal: false,
  delegated: false,
  needsConnect: false,
  connectedBy: null,
  connectUrl: null,
  via: null,
  routable: true,
  ...overrides,
})

const household = resource({})
const notes = resource({
  id: '2',
  key: 'adas-notes',
  name: "Ada's notes",
  manageable: true,
  personal: true,
  defaultStorage: false,
})

function resources(administrator: boolean) {
  return fakeClient({
    Resources: () => ({ administrator, resources: [household, notes] }),
    Runs: () => ({ runs: { nodes: [], hasMore: false, nextCursor: null } }),
  })
}

describe('Resources', () => {
  test('a member is told who changes shared places, and manages only their own', async () => {
    show(<Resources />, resources(false).client, '/settings/resources')

    expect(
      await screen.findByText(
        'Places everyone shares are changed by an administrator',
      ),
    ).toBeTruthy()

    await userEvent.click(
      screen.getByRole('button', { name: 'More for household' }),
    )
    expect(screen.queryByRole('menuitem', { name: 'Put away' })).toBeNull()
    expect(screen.queryByRole('menuitem', { name: 'Take drops' })).toBeNull()

    await userEvent.keyboard('{Escape}')
    await userEvent.click(
      screen.getByRole('button', { name: 'More for adas-notes' }),
    )
    expect(
      await screen.findByRole('menuitem', { name: 'Put away' }),
    ).toBeTruthy()
    expect(screen.queryByRole('menuitem', { name: 'Take drops' })).toBeNull()
  })

  test('a folder whose last sync came back empty says its items stay', async () => {
    const emptied = resource({
      id: '3',
      type: 'filesystem',
      key: 'media',
      emptiedAt: new Date().toISOString(),
    })
    const { client } = fakeClient({
      Resources: () => ({ administrator: true, resources: [emptied] }),
      Runs: () => ({ runs: { nodes: [], hasMore: false, nextCursor: null } }),
    })

    show(<Resources />, client, '/settings/resources')

    expect(
      await screen.findByText(/found nothing here, so its items stay/),
    ).toBeTruthy()
  })

  test('an administrator sees no such notice', async () => {
    show(<Resources />, resources(true).client, '/settings/resources')

    expect(await screen.findByText('household')).toBeTruthy()
    expect(
      screen.queryByText(
        'Places everyone shares are changed by an administrator',
      ),
    ).toBeNull()
  })

  test('What it has done opens the runs of that resource', async () => {
    const { client, asked } = resources(false)

    show(<Resources />, client, '/settings/resources')

    await userEvent.click(
      await screen.findByRole('button', { name: 'More for household' }),
    )
    await userEvent.click(
      await screen.findByRole('menuitem', { name: 'What it has done' }),
    )

    const dialog = await screen.findByRole('dialog', {
      name: 'What household has done',
    })
    expect(
      await within(dialog).findByText(/Nothing has run here yet/),
    ).toBeTruthy()
    expect(asked.find((ask) => ask.name === 'Runs')?.variables).toMatchObject({
      resourceId: '1',
    })
  })

  test('the setup checklist opens straight onto Attach', async () => {
    const { client } = fakeClient({
      Resources: () => ({ administrator: true, resources: [household] }),
      ResourceTypes: () => ({ resourceTypes: [] }),
    })

    show(<Resources />, client, '/settings/resources?attach=1')

    expect(await screen.findByRole('dialog')).toBeTruthy()
  })
})
