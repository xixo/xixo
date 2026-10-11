import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Runs } from '../../app/javascript/components/Runs'
import { fakeClient, show } from './support/screen'

const run = {
  id: '7',
  kind: 'sync',
  status: 'succeeded',
  processed: 12,
  error: null,
  createdAt: new Date().toISOString(),
  startedAt: new Date(Date.now() - 65_000).toISOString(),
  finishedAt: new Date().toISOString(),
}

describe('a list that fails to load', () => {
  test('says why, and Try again asks once more', async () => {
    let failing = true
    const { client } = fakeClient({
      Runs: () => {
        if (failing) throw new Error('[Network] Failed to fetch')
        return { runs: { nodes: [run], hasMore: false, nextCursor: null } }
      },
    })

    show(<Runs resourceId="3" />, client)

    expect(await screen.findByText('This could not be loaded')).toBeTruthy()
    expect(screen.getByText('Failed to fetch')).toBeTruthy()

    failing = false
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))

    expect(await screen.findByText('Sync')).toBeTruthy()
    expect(screen.getByText(/12 items · 1 min/)).toBeTruthy()
  })
})
