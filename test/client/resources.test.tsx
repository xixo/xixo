import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Resources } from '../../app/javascript/components/Resources'
import { fakeClient, show } from './support/screen'

const QUIET = {
  LinkRequests: () => ({ linkRequests: [] }),
  UnlinkedMachines: () => ({ unlinkedMachines: [] }),
}

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
  forOperators: false,
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

const machineSaid = (overrides: Record<string, unknown>) => ({
  hostname: 'xixo',
  version: '0.4.0',
  release: '0.4.0',
  current: true,
  updates: true,
  updatesItself: false,
  connected: true,
  seenAt: new Date().toISOString(),
  uptime: 90000,
  folders: [],
  extractors: ['pdf', 'text'],
  unread: [],
  writable: [],
  helpsOthers: true,
  heldBack: [],
  lends: false,
  tools: [],
  warnings: [],
  os: 'linux',
  arch: 'arm64',
  extractsForOthers: false,
  waiting: [],
  linked: true,
  services: [],
  memoryTotal: null,
  memoryAvailable: null,
  disks: [],
  ...overrides,
})

const local = resource({
  id: '9',
  type: 'machine',
  key: 'local',
  name: 'This server',
  capabilities: ['transport'],
  defaultStorage: false,
  changeable: false,
  machine: machineSaid({
    folders: ['/data/files'],
    extractsForOthers: true,
    services: [
      { kind: 'ollama', port: 11434, address: null, url: null, via: null },
    ],
  }),
})

const studio = resource({
  id: '7',
  type: 'machine',
  key: 'studio',
  name: 'Studio',
  capabilities: ['transport'],
  defaultStorage: false,
  manageable: true,
  machine: machineSaid({
    hostname: 'studio',
    os: 'darwin',
    folders: ['/srv/media', '/srv/photos'],
    services: [
      {
        kind: 'ollama',
        port: 11434,
        address: '100.64.0.7',
        url: 'http://100.64.0.7:11434/v1',
        via: 'home',
      },
    ],
  }),
})

function resources(administrator: boolean) {
  return fakeClient({
    ...QUIET,
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
      ...QUIET,
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

    expect(
      await screen.findByRole('heading', { name: 'Household' }),
    ).toBeTruthy()
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
      ...QUIET,
      Resources: () => ({ administrator: true, resources: [household] }),
      ResourceTypes: () => ({ resourceTypes: [] }),
    })

    show(<Resources />, client, '/settings/resources?attach=1')

    expect(await screen.findByRole('dialog')).toBeTruthy()
  })

  test('machines are the top level, and this server holds what lives nowhere else', async () => {
    const tailnet = resource({
      id: '8',
      type: 'tailnet',
      key: 'home',
      name: 'home',
      capabilities: ['transport'],
      defaultStorage: false,
      machineId: '9',
    })
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [household, tailnet, local, studio],
      }),
    })

    show(<Resources />, client, '/settings/resources')

    const headings = (await screen.findAllByRole('heading', { level: 2 })).map(
      (heading) => heading.textContent,
    )
    expect(headings).toEqual(['This server', 'Studio'])

    const server = screen.getByRole('region', { name: 'This server' })
    expect(within(server).getByText('Where xixo runs')).toBeTruthy()
    expect(
      within(server).getByText(
        'Reads every kind of file · xixo link 0.4.0, up to date',
      ),
    ).toBeTruthy()
    expect(within(server).getByText('/data/files')).toBeTruthy()
    expect(within(server).getByText('Found Ollama on This server')).toBeTruthy()
    expect(within(server).getByText('Household')).toBeTruthy()
    expect(within(server).getByText('drops land here')).toBeTruthy()
    expect(within(server).getByText('home')).toBeTruthy()
    expect(
      within(server).getByRole('button', { name: /Add to This server/ }),
    ).toBeTruthy()
    expect(screen.getByText(/Drops land in/).textContent).toBe(
      'Drops land in Household on This server',
    )
  })

  test('a model server sits under the machine whose tailnet address it dials, and anything else says the tailnet it goes through', async () => {
    const ollama = resource({
      id: '20',
      type: 'openai-compatible',
      key: 'ollama-studio',
      name: 'Ollama',
      capabilities: ['inference'],
      defaultStorage: false,
      defaultInference: true,
      via: 'home',
      machineId: '7',
      settings: { base_url: 'http://100.64.0.7:11434/v1' },
    })
    const hosted = resource({
      id: '21',
      type: 'openai-compatible',
      key: 'gpu',
      name: 'gpu',
      capabilities: ['inference'],
      defaultStorage: false,
      via: 'home',
      machineId: '9',
      settings: { base_url: 'http://100.64.0.40:8000/v1' },
    })
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [local, studio, ollama, hosted],
      }),
    })

    show(<Resources />, client, '/settings/resources')

    const machine = await screen.findByRole('region', { name: 'Studio' })
    expect(within(machine).getByText('Ollama')).toBeTruthy()
    expect(within(machine).getByText('answers questions')).toBeTruthy()
    expect(within(machine).queryByText(/Found Ollama/)).toBeNull()

    const server = screen.getByRole('region', { name: 'This server' })
    expect(
      within(server).getByText('A model server · through home'),
    ).toBeTruthy()
    expect(screen.getByText(/Questions go to/).textContent).toBe(
      'Questions go to Ollama on Studio',
    )
  })

  test('adding to a machine says its folders join the catalog by themselves, and adds a model server it found in one click', async () => {
    const media = resource({
      id: '22',
      type: 'filesystem',
      key: 'media',
      defaultStorage: false,
      via: 'studio',
      machineId: '7',
      settings: { folder: '/srv/media' },
    })
    const { client, asked } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [local, studio, media],
      }),
      AttachResource: () => ({
        attachResource: {
          resource: {
            id: '30',
            type: 'openai-compatible',
            key: 'ollama-studio',
            name: 'Ollama on Studio',
          },
          checkError: null,
          connectUrl: null,
        },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    await userEvent.click(
      await screen.findByRole('button', { name: /Add to Studio/ }),
    )
    const dialog = await screen.findByRole('dialog', { name: 'Add to Studio' })
    expect(
      within(dialog).getByText(
        'Every folder Studio shares joins the catalog by itself.',
      ),
    ).toBeTruthy()
    expect(within(dialog).queryByText('/srv/photos')).toBeNull()
    expect(within(dialog).queryByText('Reached from here')).toBeNull()

    await userEvent.click(within(dialog).getByRole('button', { name: 'Add' }))

    expect(
      asked.find((ask) => ask.name === 'AttachResource')?.variables,
    ).toMatchObject({
      type: 'openai-compatible',
      key: 'ollama-studio',
      via: 'home',
      personal: false,
      settings: { base_url: 'http://100.64.0.7:11434/v1' },
    })
  })

  test('the Add button asks where first, starting at this server', async () => {
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [local, studio],
      }),
    })

    show(<Resources />, client, '/settings/resources')

    await userEvent.click(await screen.findByRole('button', { name: 'Add' }))
    const dialog = await screen.findByRole('dialog', {
      name: 'Add a resource',
    })
    expect(
      within(dialog)
        .getByRole('button', { name: 'This server' })
        .getAttribute('aria-pressed'),
    ).toBe('true')
    expect(within(dialog).getByText('Reached from here')).toBeTruthy()

    await userEvent.click(
      within(dialog).getByRole('button', { name: 'Studio' }),
    )
    expect(within(dialog).queryByText('Reached from here')).toBeNull()
    expect(
      within(dialog).getByText(
        'Every folder Studio shares joins the catalog by itself.',
      ),
    ).toBeTruthy()
  })

  test('a machine that went offline stays calm and says when it was last seen', async () => {
    const seenAt = new Date(Date.now() - 3 * 3600 * 1000).toISOString()
    const away = resource({
      ...studio,
      healthy: false,
      checkedAt: new Date().toISOString(),
      checkError: `studio: xixo link was last heard from ${seenAt}`,
      machine: { ...studio.machine, connected: false, seenAt },
    })
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({ administrator: true, resources: [local, away] }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = await screen.findByRole('region', { name: 'Studio' })
    expect(card.getAttribute('data-away')).toBe('true')
    expect(card.querySelector('.rrow-error')).toBeNull()
    expect(within(card).getByText('offline · last seen 3h ago')).toBeTruthy()
  })

  test('files waiting to be read are counted on the machine they wait for, and above the cards when any machine that reads for others will do', async () => {
    const away = resource({
      ...studio,
      machine: {
        ...studio.machine,
        connected: false,
        waiting: [{ kind: 'pdf', count: 2 }],
      },
    })
    const short = resource({
      ...local,
      machine: {
        ...local.machine,
        lends: true,
        waiting: [
          { kind: 'media', count: 9 },
          { kind: 'pdf', count: 3 },
        ],
      },
    })
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        waitingForMachines: [{ kind: 'media', count: 12 }],
        resources: [short, away],
      }),
    })

    show(<Resources />, client, '/settings/resources')

    expect(
      await screen.findByText(
        '12 files wait for a machine that reads audio and video',
      ),
    ).toBeTruthy()
    const studioCard = screen.getByRole('region', { name: 'Studio' })
    expect(
      within(studioCard).getByText(/2 files wait for it to come back/),
    ).toBeTruthy()
    const server = screen.getByRole('region', { name: 'This server' })
    expect(
      within(server).getByText(
        /12 files wait for it to read PDFs or audio and video/,
      ),
    ).toBeTruthy()
  })

  test('linking up a machine shows one command for the system, and the machine asking appears to approve', async () => {
    const asking = {
      id: '40',
      code: 'WDJB-MJHT',
      status: 'pending',
      hostname: 'studio.local',
      os: 'darwin',
      arch: 'arm64',
      folders: ['/Users/jon/Documents'],
      writable: [],
      remoteIp: '192.0.2.4',
      expiresAt: new Date(Date.now() + 600_000).toISOString(),
      machine: null,
    }
    const { client, asked } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [household],
        linkUp: {
          xixo: 'https://xixo.example.com',
          systems: ['darwin', 'linux'],
        },
      }),
      LinkRequests: () => ({ linkRequests: [asking] }),
      ApproveLinkRequest: () => ({
        approveLinkRequest: { request: { ...asking, status: 'approved' } },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    expect(await screen.findByText('studio is asking to link up.')).toBeTruthy()
    await userEvent.click(screen.getByRole('button', { name: 'Review' }))
    const dialog = await screen.findByRole('dialog', {
      name: 'Link up a machine',
    })

    expect(
      within(dialog).getByText(
        'Run this on the machine, then approve it here.',
      ),
    ).toBeTruthy()
    expect(
      within(dialog).getByText(
        'curl -fsSL https://xixo.example.com/link.sh | sh',
      ),
    ).toBeTruthy()
    expect(within(dialog).queryByText(/enroll/)).toBeNull()

    await userEvent.click(within(dialog).getByText('macOS'))
    expect(
      within(dialog).getByText(
        'curl -fsSL https://xixo.example.com/link.sh | sh -s -- ~/Documents ~/Desktop',
      ),
    ).toBeTruthy()

    expect(within(dialog).getByText('WDJB-MJHT')).toBeTruthy()
    expect(within(dialog).getByText(/from 192\.0\.2\.4/)).toBeTruthy()
    await userEvent.click(
      within(dialog).getByRole('button', { name: 'Approve' }),
    )

    expect(
      asked.find((ask) => ask.name === 'ApproveLinkRequest')?.variables,
    ).toEqual({ id: '40' })
  })

  test('a machine card lists the folders it shares as the folders in the catalog, marks the writable ones, and an administrator turns off helping others', async () => {
    const sharing = resource({
      ...studio,
      machine: machineSaid({
        ...studio.machine,
        folders: ['/srv/media', '/srv/inbox'],
        writable: ['/srv/inbox'],
        heldBack: ['extract', 'lend'],
      }),
    })
    const media = resource({
      id: '22',
      type: 'filesystem',
      key: 'studio-media',
      name: 'media on Studio',
      itemsCount: 216,
      defaultStorage: false,
      syncable: true,
      syncInterval: 3600,
      forOperators: true,
      manageable: true,
      via: 'studio',
      machineId: '7',
      settings: { folder: '/srv/media' },
    })
    const { client, asked } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [local, sharing, media],
      }),
      SetMachineHelpsOthers: () => ({
        setMachineHelpsOthers: {
          resource: {
            id: '7',
            machine: {
              helpsOthers: false,
              heldBack: [],
              lends: true,
              tools: [],
              extractsForOthers: false,
            },
          },
        },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = await screen.findByRole('region', { name: 'Studio' })
    const shared = within(card).getByRole('list', {
      name: 'Folders studio shares',
    })
    const rows = within(shared).getAllByRole('listitem')
    expect(rows).toHaveLength(2)
    expect(within(rows[0]).getByRole('heading').textContent).toBe(
      'media on Studio',
    )
    expect(within(rows[0]).getByText('only its operators')).toBeTruthy()
    expect(rows[0].querySelector('.rrow-says')?.textContent).toBe(
      '/srv/media · 216 items · Read only',
    )
    expect(rows[1].textContent).toBe('/srv/inbox · Read and write')
    expect(
      within(card).getAllByRole('heading', { name: 'media on Studio' }),
    ).toHaveLength(1)
    expect(within(card).queryByText('Files and writing')).toBeNull()
    expect(
      within(card).getByText(
        /Its own config holds back running its readers, whole files/,
      ),
    ).toBeTruthy()

    await userEvent.click(
      within(card).getByLabelText(/^Help read files from other places/),
    )

    expect(
      asked
        .filter((ask) => ask.name === 'SetMachineHelpsOthers')
        .map((ask) => ask.variables),
    ).toEqual([{ id: '7', helpsOthers: false }])
  })

  test('an administrator shows a folder held for its operators to everyone', async () => {
    const media = resource({
      id: '22',
      type: 'filesystem',
      key: 'studio-media',
      name: 'media on Studio',
      defaultStorage: false,
      forOperators: true,
      manageable: true,
      via: 'studio',
      machineId: '7',
      settings: { folder: '/srv/media' },
    })
    const { client, asked } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [local, studio, media],
      }),
      SetFolderForEveryone: () => ({
        setFolderForEveryone: {
          resource: { id: '22', forOperators: false, manageable: true },
        },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    await userEvent.click(
      await screen.findByRole('button', { name: 'More for studio-media' }),
    )
    await userEvent.click(
      await screen.findByRole('menuitem', { name: 'Show to everyone' }),
    )

    expect(
      asked.find((ask) => ask.name === 'SetFolderForEveryone')?.variables,
    ).toEqual({ id: '22', everyone: true })
  })

  test('a machine with nothing to add but its folders has no Add to button', async () => {
    const quiet = resource({
      ...studio,
      machine: machineSaid({ ...studio.machine, services: [] }),
    })
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({ administrator: true, resources: [local, quiet] }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = await screen.findByRole('region', { name: 'Studio' })
    expect(within(card).getByText('/srv/photos')).toBeTruthy()
    expect(within(card).queryByRole('button', { name: /Add to/ })).toBeNull()
  })

  test('someone who is not an administrator sees what a machine shares, and no switches', async () => {
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({ administrator: false, resources: [local, studio] }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = await screen.findByRole('region', { name: 'Studio' })
    expect(within(card).getByText('/srv/photos')).toBeTruthy()
    expect(within(card).queryByRole('switch')).toBeNull()
  })

  test('a machine card shows its xixo link version, and an administrator pauses its updates', async () => {
    const behind = resource({
      ...studio,
      machine: machineSaid({
        ...studio.machine,
        version: '0.3.0',
        current: false,
        updatesItself: true,
      }),
    })
    const { client, asked } = fakeClient({
      ...QUIET,
      Resources: () => ({ administrator: true, resources: [local, behind] }),
      SetMachineUpdates: () => ({
        setMachineUpdates: {
          resource: { id: '7', machine: { updates: false, current: false } },
        },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = await screen.findByRole('region', { name: 'Studio' })
    expect(
      within(card).getByText(/xixo link 0\.3\.0, updating to 0\.4\.0/),
    ).toBeTruthy()

    const server = await screen.findByRole('region', { name: 'This server' })
    expect(within(server).queryByText(/updating to/)).toBeNull()
    expect(
      within(server).queryByLabelText('Update xixo link automatically'),
    ).toBeNull()

    await userEvent.click(
      within(card).getByLabelText('Update xixo link automatically'),
    )

    expect(
      asked.find((ask) => ask.name === 'SetMachineUpdates')?.variables,
    ).toEqual({ id: '7', automatic: false })
  })

  test('a machine linked before updates is told to run the link-up command once, even at the same version', async () => {
    const early = resource({
      ...studio,
      machine: machineSaid({
        ...studio.machine,
        version: '0.4.0',
        current: null,
        updatesItself: false,
      }),
    })
    const { client } = fakeClient({
      ...QUIET,
      Resources: () => ({ administrator: true, resources: [local, early] }),
    })

    show(<Resources />, client, '/settings/resources')

    const card = await screen.findByRole('region', { name: 'Studio' })
    expect(
      within(card).getByText(
        /xixo link 0\.4\.0\. Run the link-up command again so it updates itself/,
      ),
    ).toBeTruthy()
    expect(within(card).queryByText(/up to date/)).toBeNull()
    expect(
      within(card).queryByLabelText('Update xixo link automatically'),
    ).toBeNull()
  })

  test('a tailnet machine that is not linked shows a model server to add in one click', async () => {
    const { client, asked } = fakeClient({
      ...QUIET,
      Resources: () => ({
        administrator: true,
        resources: [local],
        linkUp: { xixo: 'https://xixo.example.com', systems: ['linux'] },
      }),
      UnlinkedMachines: () => ({
        unlinkedMachines: [
          {
            hostName: 'm2',
            dnsName: 'm2.example.ts.net',
            addresses: ['100.64.0.8'],
            via: 'home',
            services: [
              {
                name: 'ollama',
                port: 11434,
                type: 'openai-compatible',
                address: 'http://100.64.0.8:11434/v1',
              },
            ],
          },
        ],
      }),
      AttachResource: () => ({
        attachResource: {
          resource: {
            id: '31',
            type: 'openai-compatible',
            key: 'ollama-m2',
            name: 'Ollama on m2',
          },
          checkError: null,
          connectUrl: null,
        },
      }),
    })

    show(<Resources />, client, '/settings/resources')

    expect(await screen.findByText('Not linked yet')).toBeTruthy()
    await userEvent.click(
      screen.getByRole('button', { name: 'Add Ollama on m2' }),
    )

    expect(
      asked.find((ask) => ask.name === 'AttachResource')?.variables,
    ).toMatchObject({
      type: 'openai-compatible',
      key: 'ollama-m2',
      via: 'home',
      settings: { base_url: 'http://100.64.0.8:11434/v1' },
    })
  })
})
