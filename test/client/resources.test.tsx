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
        'Places everyone shares are changed by an administrator.',
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

    expect(await screen.findByText('Household')).toBeTruthy()
    expect(
      screen.queryByText(
        'Places everyone shares are changed by an administrator.',
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

  test('machines come first, this server among them, and say plainly what they share', async () => {
    const local = resource({
      id: '9',
      type: 'machine',
      key: 'local',
      name: 'This server',
      capabilities: ['transport'],
      changeable: false,
      machine: {
        hostname: 'xixo',
        version: '0.4.0',
        connected: true,
        seenAt: new Date().toISOString(),
        uptime: 90000,
        folders: ['/data/files'],
        extractors: ['pdf', 'text'],
        unread: [],
        lends: false,
        tools: [],
        warnings: [],
        os: 'linux',
        arch: 'arm64',
        extractsForOthers: true,
        linked: true,
        selfLinked: false,
        linkingUntil: null,
        services: [{ kind: 'ollama', port: 11434 }],
        memoryTotal: null,
        memoryAvailable: null,
        disks: [],
      },
    })
    const tailnet = resource({
      id: '8',
      type: 'tailnet',
      key: 'home',
      name: 'home',
      capabilities: ['transport'],
    })
    const { client } = fakeClient({
      Resources: () => ({
        administrator: true,
        resources: [household, tailnet, local],
      }),
    })

    show(<Resources />, client, '/settings/resources')

    const headings = (await screen.findAllByRole('heading', { level: 2 })).map(
      (heading) => heading.textContent,
    )
    expect(headings).toEqual(['Machines', 'Storage', 'Connections'])
    expect(screen.getByText('This server')).toBeTruthy()
    expect(screen.getByText('The machine xixo runs on')).toBeTruthy()
    expect(screen.getByText('Shares 1 folder')).toBeTruthy()
    expect(screen.getByText('Reads every kind of file')).toBeTruthy()
    expect(screen.getByText('Also reads for other machines')).toBeTruthy()
    expect(screen.getByText('Has Ollama')).toBeTruthy()
    expect(
      screen.getByText('A folder on this server, where your uploads go'),
    ).toBeTruthy()
    expect(screen.queryByText('reachable')).toBeNull()
  })

  test('a machine that went offline stays calm and says when it was last seen', async () => {
    const seenAt = new Date(Date.now() - 3 * 3600 * 1000).toISOString()
    const studio = resource({
      id: '7',
      type: 'machine',
      key: 'studio',
      name: 'Studio',
      capabilities: ['transport'],
      healthy: false,
      checkedAt: new Date().toISOString(),
      checkError: `studio: xixo link was last heard from ${seenAt}`,
      machine: {
        hostname: 'studio',
        version: '0.4.0',
        connected: false,
        seenAt,
        uptime: null,
        folders: ['/srv/media'],
        extractors: ['text'],
        unread: [],
        lends: false,
        tools: [],
        warnings: [],
        os: 'linux',
        arch: 'amd64',
        extractsForOthers: false,
        linked: true,
        selfLinked: true,
        linkingUntil: null,
        services: [],
        memoryTotal: null,
        memoryAvailable: null,
        disks: [],
      },
    })
    const { client } = fakeClient({
      Resources: () => ({ administrator: true, resources: [studio] }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = (await screen.findByText('Studio')).closest('article')
    expect(card?.getAttribute('data-failing')).toBe('false')
    expect(card?.querySelector('.rcard-error')).toBeNull()
    expect(within(card as HTMLElement).getByText('offline')).toBeTruthy()
    expect(within(card as HTMLElement).getByText(/^Last seen /)).toBeTruthy()
  })

  test('linking up a machine names it, then shows commands carrying the code', async () => {
    const { client, asked } = fakeClient({
      Resources: () => ({
        administrator: true,
        resources: [household],
        linkUp: {
          xixo: 'https://xixo.example.com',
          issuer: 'https://id.example.com',
          builds: [
            {
              os: 'linux',
              arch: 'amd64',
              file: 'xixo-link-linux-amd64',
              sha256: 'a'.repeat(64),
            },
          ],
        },
      }),
      LinkMachine: () => ({
        linkMachine: {
          resource: { id: '7', key: 'studio', name: 'studio' },
          code: 'enroll-secret',
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
        },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    await userEvent.click(
      await screen.findByRole('button', { name: /Link up a machine/ }),
    )
    const dialog = await screen.findByRole('dialog', {
      name: 'Link up a machine',
    })
    await userEvent.type(
      within(dialog).getByLabelText(/Name the machine/),
      'studio',
    )
    await userEvent.click(
      within(dialog).getByRole('button', { name: 'Show the commands' }),
    )

    expect(await within(dialog).findByText('Get xixo link')).toBeTruthy()
    expect(within(dialog).getByText(/code='enroll-secret'/)).toBeTruthy()
    expect(
      within(dialog).getByText(/Waiting for studio to link up/),
    ).toBeTruthy()
    expect(
      asked.find((ask) => ask.name === 'LinkMachine')?.variables,
    ).toMatchObject({ key: 'studio' })
  })
})
