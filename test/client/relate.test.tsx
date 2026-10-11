import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Relate } from '../../app/javascript/components/Relate'
import { fakeClient, page, show } from './support/screen'

const lease = {
  id: '2',
  type: 'xixo:file',
  key: 'lease.pdf',
  title: 'lease.pdf',
  mime: 'application/pdf',
  summary: 'The lease runs to June.',
}
const deposit = {
  id: '3',
  type: 'xixo:file',
  key: 'deposit.pdf',
  title: 'deposit.pdf',
  mime: 'application/pdf',
  summary: null,
}

describe('Relate', () => {
  test('lists what is related now, and a search relates another item', async () => {
    let changed = 0
    const related = [deposit]
    const { client, asked } = fakeClient({
      Catalog: () => ({ feeds: page(related) }),
      Search: () => ({ search: page([{ ...lease, id: '1' }, lease, deposit]) }),
      ConnectFeeds: (variables) => {
        related.push(lease)
        return {
          connectFeeds: { feed: { id: variables.id, connectedCount: 2 } },
        }
      },
    })

    show(
      <Relate
        item={{ id: '1', name: 'invoice.pdf' }}
        onClose={() => {}}
        onChanged={() => changed++}
      />,
      client,
    )

    expect(await screen.findByText('Related now')).toBeTruthy()
    expect(screen.getByText('deposit.pdf')).toBeTruthy()

    await userEvent.type(
      screen.getByPlaceholderText(/Search for an item/),
      'lease',
    )

    const relate = await screen.findByRole('button', { name: 'Relate' })
    expect(screen.getAllByText('lease.pdf')).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Unrelate' })).toBeTruthy()

    await userEvent.click(relate)

    await waitFor(() =>
      expect(screen.getAllByRole('button', { name: 'Unrelate' })).toHaveLength(
        2,
      ),
    )
    expect(asked.find((ask) => ask.name === 'ConnectFeeds')?.variables).toEqual(
      { id: '1', otherId: '2', connected: true },
    )
    expect(changed).toBe(0)

    await userEvent.keyboard('{Escape}')
    expect(changed).toBe(1)
  })
})
