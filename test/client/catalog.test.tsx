import { screen } from '@testing-library/react'
import { describe, expect, test } from 'vitest'
import { AddProvider } from '../../app/javascript/components/Add'
import { Catalog } from '../../app/javascript/components/Catalog'
import { UploadsProvider } from '../../app/javascript/components/Uploads'
import { fakeClient, show } from './support/screen'

const empty = { nodes: [], hasMore: false, nextCursor: null, total: 0 }

function catalog(rows: unknown[]) {
  return fakeClient({
    Settings: () => ({
      settings: [{ key: 'setup_checklist', level: 'personal', value: 'shown' }],
    }),
    Setup: () => ({
      setup: { storage: false, inference: false, client: false },
    }),
    Feeds: () => ({ feeds: empty }),
    Catalog: () => ({ feeds: { ...empty, nodes: rows } }),
    Types: () => ({ types: [] }),
  })
}

function showCatalog(rows: unknown[]) {
  return show(
    <UploadsProvider>
      <AddProvider>
        <Catalog />
      </AddProvider>
    </UploadsProvider>,
    catalog(rows).client,
  )
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
})
