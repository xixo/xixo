import { fireEvent, screen } from '@testing-library/react'
import { describe, expect, test } from 'vitest'
import type { PassFragment } from 'xixo'
import { Passes } from '../../app/javascript/components/Passes'
import { fakeClient, show } from './support/screen'

const pass = (overrides: Partial<PassFragment>) =>
  ({
    id: '5',
    cause: 'sync',
    question: null,
    drewOn: [],
    status: 'done',
    error: null,
    waiting: null,
    said: null,
    steps: {},
    lines: 0,
    createdAt: new Date().toISOString(),
    finishedAt: null,
    durationMs: null,
    ...overrides,
  }) as PassFragment

describe('Passes', () => {
  test('a parked pass says it is waiting, and for what', async () => {
    const { client } = fakeClient({})

    show(
      <Passes
        passes={[
          pass({
            status: 'parked',
            waiting: 'Waiting for a machine that can read audio and video.',
          }),
        ]}
        onSettled={() => {}}
      />,
      client,
    )

    expect(await screen.findByText('waiting')).toBeTruthy()
    expect(
      screen.getByText('Waiting for a machine that can read audio and video.'),
    ).toBeTruthy()
  })

  test('a pass waiting for a model server says so, and its summary step is not marked failed', async () => {
    const { client } = fakeClient({
      AnalysisLog: () => ({ analysis: { id: '5', logs: '' } }),
    })

    show(
      <Passes
        passes={[
          pass({
            status: 'parked',
            waiting: 'Waiting for geiger-m2 to come online.',
            steps: {
              summary: {
                error: {
                  class: 'Analyzer::Waiting',
                  message: 'ollama: geiger-m2 is offline',
                },
              },
              text: { result: 'milk' },
            },
          }),
        ]}
        onSettled={() => {}}
      />,
      client,
    )

    expect(
      await screen.findByText('Waiting for geiger-m2 to come online.'),
    ).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { expanded: false }))

    const step = screen
      .getByText('ollama: geiger-m2 is offline')
      .closest('.pass-step')
    expect(step?.getAttribute('data-failed')).toBe('false')
    expect(step?.getAttribute('data-waiting')).toBe('true')
  })

  test('a pass stays on screen when an update arrives with nothing in it', async () => {
    const { client } = fakeClient({ AnalysisProgressed: () => ({}) })

    show(
      <Passes passes={[pass({ status: 'running' })]} onSettled={() => {}} />,
      client,
    )

    expect(await screen.findByText('running')).toBeTruthy()
  })
})
