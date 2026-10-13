import { screen } from '@testing-library/react'
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

  test('a pass stays on screen when an update arrives with nothing in it', async () => {
    const { client } = fakeClient({ AnalysisProgressed: () => ({}) })

    show(
      <Passes passes={[pass({ status: 'running' })]} onSettled={() => {}} />,
      client,
    )

    expect(await screen.findByText('running')).toBeTruthy()
  })
})
