import { fireEvent, screen, waitFor } from '@testing-library/react'
import { describe, expect, test } from 'vitest'
import { AddProvider } from '../../app/javascript/components/Add'
import { Catalog } from '../../app/javascript/components/Catalog'
import { UploadsProvider } from '../../app/javascript/components/Uploads'
import { fakeClient, page, show } from './support/screen'

const counts = {
  where: [
    { key: '2', count: 7 },
    { key: '3', count: 4 },
  ],
  analysis: [
    { key: 'analyzed', count: 3 },
    { key: 'waiting', count: 6 },
    { key: 'parked', count: 2 },
    { key: 'failed', count: 0 },
  ],
  kind: [
    { key: 'image', count: 5 },
    { key: 'pdf', count: 0 },
  ],
  when: [
    { key: 'day', count: 1 },
    { key: 'week', count: 2 },
    { key: 'month', count: 3 },
    { key: 'year', count: 11 },
  ],
}

const row = {
  id: '9',
  type: 'xixo:file',
  key: 'clip.mp4',
  title: 'clip.mp4',
  mime: 'video/mp4',
  summary: null,
  thumbnailUrl: null,
  staged: false,
  analyzedAt: null,
  unsummarized: 'Waiting for box, where it lives, to come back.',
  createdAt: new Date().toISOString(),
  parent: null,
}

function showFiltered(at = '/') {
  const fake = fakeClient({
    Settings: () => ({
      settings: [
        { key: 'setup_checklist', level: 'personal', value: 'hidden' },
      ],
    }),
    Feeds: () => ({ feeds: page([]) }),
    Catalog: () => ({ feeds: page([row]) }),
    Types: () => ({ types: [] }),
    SliceCounts: () => ({ sliceCounts: counts }),
    Places: () => ({
      resources: [
        { id: '1', type: 'machine', key: 'box', name: 'box', machineId: null },
        {
          id: '2',
          type: 'filesystem',
          key: 'media',
          name: 'Media',
          machineId: '1',
        },
        { id: '3', type: 's3', key: 'bucket', name: null, machineId: null },
      ],
    }),
  })

  show(
    <UploadsProvider>
      <AddProvider>
        <Catalog />
      </AddProvider>
    </UploadsProvider>,
    fake.client,
    at,
  )

  return fake
}

describe('Filters', () => {
  test('the list opens unfiltered, with a chip for each filter', async () => {
    const { asked } = showFiltered()

    expect(await screen.findByRole('button', { name: 'Where' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Analysis' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Kind' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'When' })).toBeTruthy()

    await waitFor(() =>
      expect(asked.map((ask) => ask.name)).toContain('Catalog'),
    )
    const listed = asked.find((ask) => ask.name === 'Catalog')
    expect(listed?.variables.analysis).toBeNull()
    expect(listed?.variables.machineId).toBeNull()
  })

  test('a menu shows how many each choice holds, and picking one filters the list', async () => {
    const { asked } = showFiltered()

    fireEvent.click(await screen.findByRole('button', { name: 'Where' }))
    expect(await screen.findByText('Media')).toBeTruthy()
    expect(screen.getByText('bucket')).toBeTruthy()
    expect(screen.getAllByText('7').length).toBeGreaterThan(0)

    fireEvent.click(screen.getByText('Media'))

    expect(
      await screen.findByRole('button', { name: 'Where: Media' }),
    ).toBeTruthy()
    await waitFor(() =>
      expect(
        asked.some(
          (ask) => ask.name === 'Catalog' && ask.variables.resourceId === '2',
        ),
      ).toBe(true),
    )
  })

  test('filters set in the address are filled chips with a clear mark, and a waiting row says what it waits for', async () => {
    const { asked } = showFiltered('/?analysis=parked&kind=image&added=week')

    expect(
      await screen.findByRole('button', {
        name: 'Analysis: Waiting for a machine or a model server',
      }),
    ).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Kind: images' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'When: Past week' })).toBeTruthy()
    expect(
      await screen.findByText('Waiting for box, where it lives, to come back.'),
    ).toBeTruthy()

    const listed = asked.find((ask) => ask.name === 'Catalog')
    expect(listed?.variables.analysis).toBe('parked')
    expect(listed?.variables.kind).toBe('image')
    expect(typeof listed?.variables.since).toBe('string')

    fireEvent.click(screen.getByRole('button', { name: 'Clear kind' }))

    expect(await screen.findByRole('button', { name: 'Kind' })).toBeTruthy()
  })
})
