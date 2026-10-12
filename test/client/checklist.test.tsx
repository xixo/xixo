import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import { Setup } from '../../app/javascript/components/Setup'
import { fakeClient, show } from './support/screen'

const setup =
  (
    storage: boolean,
    inference: boolean,
    client: boolean,
    held: Record<string, unknown> = {},
  ) =>
  () => ({
    setup: {
      storage,
      inference,
      client,
      storageResource: null,
      inferenceResource: null,
      connectedClient: null,
      ...held,
    },
  })

const files = {
  id: '7',
  key: 'files',
  name: null,
  kind: 'a folder on this server',
  model: null,
  down: false,
}

const ollama = {
  id: '9',
  key: 'ollama',
  name: null,
  kind: 'a model server',
  model: 'gemma3:4b',
  down: false,
}

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

  test('names what took care of each step and links to it', async () => {
    const { client } = fakeClient({
      Setup: setup(true, true, false, {
        storageResource: files,
        inferenceResource: ollama,
      }),
    })

    show(<Setup onHidden={() => {}} />, client)

    expect(
      (
        await screen.findByRole('link', {
          name: 'files, a folder on this server',
        })
      ).getAttribute('href'),
    ).toBe('/settings/resources/7')
    expect(
      screen
        .getByRole('link', { name: 'ollama (gemma3:4b answers questions)' })
        .getAttribute('href'),
    ).toBe('/settings/resources/9')
    expect(
      screen.queryByRole('link', { name: 'Attach a model server' }),
    ).toBeNull()
  })

  test('points at a model server that stopped answering', async () => {
    const { client } = fakeClient({
      Setup: setup(true, false, true, {
        storageResource: files,
        inferenceResource: { ...ollama, down: true },
        connectedClient: {
          name: 'claude-code',
          person: 'Ada',
          at: new Date().toISOString(),
        },
      }),
    })

    show(<Setup onHidden={() => {}} />, client)

    expect(
      (
        await screen.findByRole('link', {
          name: 'ollama (not answering its check)',
        })
      ).getAttribute('href'),
    ).toBe('/settings/resources/9')
    expect(
      screen
        .getByRole('link', {
          name: 'claude-code for Ada, last called a tool just now',
        })
        .getAttribute('href'),
    ).toBe('/settings/activity')
    expect(
      screen.getByRole('link', { name: 'Attach a model server' }),
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
