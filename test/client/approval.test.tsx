import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Route, Routes } from 'react-router-dom'
import { describe, expect, test } from 'vitest'
import { LinkApproval } from '../../app/javascript/components/LinkApproval'
import { fakeClient, show } from './support/screen'

const asking = (overrides: Record<string, unknown> = {}) => ({
  id: '40',
  code: 'WDJB-MJHT',
  status: 'pending',
  hostname: 'studio.local',
  os: 'darwin',
  arch: 'arm64',
  folders: ['/Users/jon/Desktop', '/Users/jon/Documents'],
  writable: ['/Users/jon/Desktop'],
  remoteIp: '192.0.2.4',
  expiresAt: new Date(Date.now() + 8 * 60_000).toISOString(),
  createdAt: new Date(Date.now() - 2 * 60_000).toISOString(),
  user: 'jon',
  system: 'macOS 26.0',
  model: 'Mac14,7',
  version: '0.2.0',
  cpus: 10,
  memory: String(16 * 1024 ** 3),
  disks: [
    {
      path: '/Users/jon/Desktop',
      total: String(500 * 1024 ** 3),
      free: String(120 * 1024 ** 3),
    },
  ],
  addresses: ['192.168.1.20', '100.64.0.1'],
  services: [{ kind: 'ollama', port: 11434 }],
  battery: true,
  readers: ['pdf', 'text'],
  gpus: [
    {
      maker: 'Apple',
      model: 'Apple M2 Max',
      memory: String(64 * 1024 ** 3),
      driver: 'built in',
    },
  ],
  plan: [
    {
      key: 'catalog',
      says: 'Catalog Documents. Read and write Desktop.',
      why: null,
      on: true,
      possible: true,
    },
    {
      key: 'extract',
      says: 'Extract text from documents, and from files other machines lend it.',
      why: 'It reads PDFs and text.',
      on: true,
      possible: true,
    },
    {
      key: 'models',
      says: 'Run no models.',
      why: 'It has no GPU xixo can run models on, so models run on another machine.',
      on: false,
      possible: false,
    },
  ],
  sameAddress: false,
  linksAs: 'studio-2',
  namedLike: 'studio',
  machine: null,
  ...overrides,
})

function approve(request: Record<string, unknown> | null) {
  const { client, asked } = fakeClient({
    LinkRequest: () => ({ administrator: true, linkRequest: request }),
    ApproveLinkRequest: () => ({
      approveLinkRequest: { request: { ...request, status: 'approved' } },
    }),
  })

  show(
    <Routes>
      <Route path="/link/:code" element={<LinkApproval />} />
    </Routes>,
    client,
    '/link/WDJB-MJHT',
  )

  return asked
}

describe('approving a machine', () => {
  test('the page leads with the machine and lists what it says about itself', async () => {
    approve(asking())

    expect(
      await screen.findByRole('heading', { name: 'Approve studio' }),
    ).toBeTruthy()
    expect(document.title).toBe('Approve studio · xixo')
    expect(screen.getByText('macOS 26.0 · Mac14,7 · arm64')).toBeTruthy()
    expect(screen.getByText('WDJB-MJHT')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Approve' })).toBeTruthy()
    expect(
      screen.getByText('Read and write · 120 GB free of 500 GB'),
    ).toBeTruthy()
    expect(screen.getByText('Read only')).toBeTruthy()
    expect(screen.getByText('10 cores · 16 GB memory · a battery')).toBeTruthy()
    expect(screen.getByText('Apple M2 Max, 64 GB')).toBeTruthy()
    expect(screen.getByText('pdf, text')).toBeTruthy()
    expect(screen.getByText('192.168.1.20, 100.64.0.1')).toBeTruthy()
    expect(
      screen.getByText('A different address than this browser'),
    ).toBeTruthy()
    expect(screen.getByText('Ollama on port 11434')).toBeTruthy()
    expect(screen.getByText(/runs out in 8 minutes/)).toBeTruthy()
    expect(
      screen.getByText(/A machine named studio is already linked/),
    ).toBeTruthy()
  })

  test('the plan shows as switches, and approving sends the lines switched off', async () => {
    const asked = approve(asking())

    const extract = await screen.findByLabelText(/^Extract text from documents/)
    expect(extract).toHaveProperty('checked', true)
    expect(screen.getByText('It reads PDFs and text.')).toBeTruthy()
    const models = screen.getByLabelText(/^Run no models\./)
    expect(models).toHaveProperty('checked', false)
    expect(models).toHaveProperty('disabled', true)

    await userEvent.click(extract)
    await userEvent.click(screen.getByRole('button', { name: 'Approve' }))

    expect(
      asked
        .filter((ask) => ask.name === 'ApproveLinkRequest')
        .map((ask) => ask.variables),
    ).toEqual([{ id: '40', off: ['extract'] }])
  })

  test('once linked, the title says so', async () => {
    approve(
      asking({
        status: 'linked',
        namedLike: null,
        machine: { id: '9', key: 'studio-2', machine: { connected: true } },
      }),
    )

    expect(
      await screen.findByRole('heading', { name: 'studio-2 is linked up' }),
    ).toBeTruthy()
    expect(screen.getByText(/studio-2 is ready/)).toBeTruthy()
    expect(screen.queryByText(/already linked/)).toBeNull()
  })

  test('a code nobody is asking with keeps the plain title', async () => {
    approve(null)

    expect(
      await screen.findByRole('heading', { name: 'Approve a machine' }),
    ).toBeTruthy()
    expect(screen.getByText(/No machine is asking with that code/)).toBeTruthy()
  })
})
