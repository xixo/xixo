import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Setup } from '../../app/javascript/components/Setup'
import { fakeClient, show } from './support/screen'

const setup =
  (storage: boolean, inference: boolean, client: boolean) => () => ({
    setup: { storage, inference, client },
  })

describe('Setup', () => {
  test('lists what is left and how to do it', async () => {
    const { client } = fakeClient({ Setup: setup(true, false, false) })

    show(<Setup onHidden={() => {}} />, client)

    expect(await screen.findByText('2 things are left.')).toBeTruthy()
    expect(screen.queryByRole('link', { name: 'Attach storage' })).toBeNull()
    expect(
      screen
        .getByRole('link', { name: 'Attach a model server' })
        .getAttribute('href'),
    ).toBe('/settings/resources?attach=1')
    expect(
      screen.getByText(/claude mcp add --transport http xixo .*\/mcp/),
    ).toBeTruthy()
  })

  test('is gone once everything is in place', async () => {
    const { client, asked } = fakeClient({ Setup: setup(true, true, true) })
    const { container } = show(<Setup onHidden={() => {}} />, client)

    await waitFor(() => expect(asked).toHaveLength(1))
    expect(container.querySelector('.setup')).toBeNull()
  })

  test('Hide keeps the choice as a personal setting', async () => {
    let hidden = 0
    const { client, asked } = fakeClient({
      Setup: setup(false, false, false),
      SetSetting: (variables) => ({ setSetting: { setting: variables } }),
    })

    show(<Setup onHidden={() => hidden++} />, client)
    await userEvent.click(await screen.findByRole('button', { name: 'Hide' }))

    await waitFor(() => expect(hidden).toBe(1))
    expect(asked.find((ask) => ask.name === 'SetSetting')?.variables).toEqual({
      key: 'setup_checklist',
      value: 'hidden',
    })
  })
})
