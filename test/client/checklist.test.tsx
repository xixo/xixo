import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Setup } from '../../app/javascript/components/Setup'
import { fakeClient, show } from './support/screen'

const settings = (value: string) => () => ({
  settings: [{ key: 'setup_checklist', level: 'personal', value }],
})
const setup =
  (storage: boolean, inference: boolean, client: boolean) => () => ({
    setup: { storage, inference, client },
  })

describe('Setup', () => {
  test('lists what is left and how to do it', async () => {
    const { client } = fakeClient({
      Setup: setup(true, false, false),
      Settings: settings('shown'),
    })

    show(<Setup />, client)

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

  test('is gone once everything is in place, or once it is hidden', async () => {
    const done = fakeClient({
      Setup: setup(true, true, true),
      Settings: settings('shown'),
    })
    const { container } = show(<Setup />, done.client)

    await waitFor(() =>
      expect(done.asked.map((ask) => ask.name)).toContain('Settings'),
    )
    expect(container.querySelector('.setup')).toBeNull()

    const hidden = fakeClient({
      Setup: setup(false, false, false),
      Settings: settings('hidden'),
    })
    const shown = show(<Setup />, hidden.client)

    await waitFor(() => expect(hidden.asked).toHaveLength(2))
    expect(shown.container.querySelector('.setup')).toBeNull()
  })

  test('Hide keeps the choice as a personal setting', async () => {
    const { client, asked } = fakeClient({
      Setup: setup(false, false, false),
      Settings: settings('shown'),
      SetSetting: (variables) => ({ setSetting: { setting: variables } }),
    })

    show(<Setup />, client)
    await userEvent.click(await screen.findByRole('button', { name: 'Hide' }))

    await waitFor(() =>
      expect(asked.find((ask) => ask.name === 'SetSetting')?.variables).toEqual(
        {
          key: 'setup_checklist',
          value: 'hidden',
        },
      ),
    )
  })
})
