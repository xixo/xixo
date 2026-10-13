import { screen } from '@testing-library/react'
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
  sameAddress: false,
  linksAs: 'studio-2',
  namedLike: 'studio',
  machine: null,
  ...overrides,
})

function approve(request: Record<string, unknown> | null) {
  const client = fakeClient({
    LinkRequest: () => ({ administrator: true, linkRequest: request }),
  }).client

  return show(
    <Routes>
      <Route path="/link/:code" element={<LinkApproval />} />
    </Routes>,
    client,
    '/link/WDJB-MJHT',
  )
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
    expect(screen.getByText('10 cores · 16 GB memory')).toBeTruthy()
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
