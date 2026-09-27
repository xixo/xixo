import { afterEach, describe, expect, test, vi } from 'vitest'
import {
  type Dropped,
  type Failure,
  type Twin,
  upload,
} from '../../app/javascript/uploads'

function watching() {
  const failures: Failure[] = []
  const sent: string[] = []
  const twins: Twin[] = []

  return {
    failures,
    sent,
    twins,
    handlers: {
      onFound: () => {},
      onWalked: () => {},
      onSent: (path: string) => sent.push(path),
      onTwin: (twin: Twin) => twins.push(twin),
      onFailed: (failure: Failure) => failures.push(failure),
    },
  }
}

function batch(count: number): Dropped[] {
  return Array.from({ length: count }, (_, at) => ({
    path: `file-${at}.txt`,
    open: async () => new File(['x'], `file-${at}.txt`),
  }))
}

function answering(status: number, error?: string) {
  return vi.fn(async () => ({
    ok: status >= 200 && status < 300,
    status,
    json: async () => (error ? { error } : {}),
  }))
}

afterEach(() => vi.unstubAllGlobals())

describe('upload', () => {
  test('sends everything and reports each path', async () => {
    vi.stubGlobal('fetch', answering(200))

    const seen = watching()

    await upload(
      { files: batch(3) },
      seen.handlers,
      null,
      new AbortController().signal,
    )

    expect(seen.sent.sort()).toEqual(['file-0.txt', 'file-1.txt', 'file-2.txt'])
    expect(seen.failures).toEqual([])
  })

  test('reports a file the server already holds as a twin, not as sent', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({
        ok: true,
        status: 200,
        json: async () => ({ duplicate: true, twin: 'drop/march.txt' }),
      })),
    )

    const seen = watching()

    await upload(
      { files: batch(1) },
      seen.handlers,
      null,
      new AbortController().signal,
    )

    expect(seen.sent).toEqual([])
    expect(seen.failures).toEqual([])
    expect(seen.twins).toEqual([{ path: 'file-0.txt', twin: 'drop/march.txt' }])
  })

  test('settles when a drop larger than the buffer is stopped part way', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        await new Promise((resolve) => setTimeout(resolve, 5))

        return { ok: true, status: 200, json: async () => ({}) }
      }),
    )

    const control = new AbortController()
    const seen = watching()

    const running = upload(
      { files: batch(2000) },
      seen.handlers,
      null,
      control.signal,
    )

    setTimeout(() => control.abort(), 20)

    await expect(
      Promise.race([
        running.then(() => 'settled'),
        new Promise((resolve) => setTimeout(() => resolve('hung'), 2000)),
      ]),
    ).resolves.toBe('settled')
  })

  test('a refusal is reported once rather than asked three times', async () => {
    const fetching = answering(422, 'that kind is not accepted')

    vi.stubGlobal('fetch', fetching)

    const seen = watching()

    await upload(
      { files: batch(1) },
      seen.handlers,
      null,
      new AbortController().signal,
    )

    expect(fetching).toHaveBeenCalledTimes(1)
    expect(seen.failures).toEqual([
      { path: 'file-0.txt', reason: 'that kind is not accepted' },
    ])
  })

  test('a server that is merely struggling is asked again', async () => {
    const fetching = answering(503)

    vi.stubGlobal('fetch', fetching)

    const seen = watching()

    await upload(
      { files: batch(1) },
      seen.handlers,
      null,
      new AbortController().signal,
    )

    expect(fetching).toHaveBeenCalledTimes(3)
    expect(seen.failures).toHaveLength(1)
  })

  test('signing out mid-batch raises rather than failing every file in turn', async () => {
    vi.stubGlobal('fetch', answering(401))

    const seen = watching()

    await expect(
      upload(
        { files: batch(20) },
        seen.handlers,
        null,
        new AbortController().signal,
      ),
    ).rejects.toThrow(/sign in again/)

    expect(seen.failures).toEqual([])
  })
})
