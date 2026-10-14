import { screen, waitFor } from '@testing-library/react'
import { describe, expect, test } from 'vitest'
import { AddProvider } from '../../app/javascript/components/Add'
import { Catalog } from '../../app/javascript/components/Catalog'
import { UploadsProvider } from '../../app/javascript/components/Uploads'
import { fakeClient, page, show } from './support/screen'

function showCatalog(
  rows: unknown[],
  checklist = 'shown',
  feeds: unknown = page(rows),
) {
  const fake = fakeClient({
    Settings: () => ({
      settings: [
        { key: 'setup_checklist', level: 'personal', value: checklist },
      ],
    }),
    Setup: () => ({
      setup: { storage: false, inference: false, client: false },
    }),
    Feeds: () => ({ feeds: page([]) }),
    Catalog: () => ({ feeds }),
    Types: () => ({ types: [] }),
  })

  show(
    <UploadsProvider>
      <AddProvider>
        <Catalog />
      </AddProvider>
    </UploadsProvider>,
    fake.client,
  )

  return fake
}

describe('Catalog', () => {
  test('a new install shows what it still needs above a way to add the first file', async () => {
    showCatalog([])

    expect(await screen.findByText('Getting set up')).toBeTruthy()
    expect(await screen.findByText('Nothing kept yet')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Choose files' })).toBeTruthy()
  })

  test('lists what it keeps', async () => {
    showCatalog([
      {
        id: '9',
        type: 'xixo:file',
        key: 'lease.pdf',
        title: 'lease.pdf',
        mime: 'application/pdf',
        summary: 'The lease runs to June.',
        thumbnailUrl: null,
        staged: false,
        analyzedAt: new Date().toISOString(),
        createdAt: new Date().toISOString(),
        parent: null,
      },
    ])

    expect(await screen.findByText('lease.pdf')).toBeTruthy()
    expect(screen.queryByText('Nothing kept yet')).toBeNull()
  })

  test('counts everything in the catalog, not only the rows loaded so far', async () => {
    const row = {
      id: '9',
      type: 'xixo:file',
      key: 'lease.pdf',
      title: 'lease.pdf',
      mime: 'application/pdf',
      summary: null,
      thumbnailUrl: null,
      staged: false,
      analyzedAt: null,
      createdAt: new Date().toISOString(),
      parent: null,
    }
    showCatalog([row], 'hidden', {
      nodes: [row],
      hasMore: true,
      nextCursor: '9',
      total: 4321,
    })

    expect(await screen.findByText('4,321')).toBeTruthy()
    expect(screen.queryByText(/so far/)).toBeNull()
  })

  test('a hidden checklist is never asked for', async () => {
    const { asked } = showCatalog([], 'hidden')

    expect(await screen.findByText('Nothing kept yet')).toBeTruthy()
    await waitFor(() =>
      expect(asked.map((ask) => ask.name)).toContain('Settings'),
    )
    expect(asked.map((ask) => ask.name)).not.toContain('Setup')
    expect(screen.queryByText('Getting set up')).toBeNull()
  })
})
