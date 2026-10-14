import { describe, expect, test } from 'vitest'
import {
  disks,
  does,
  humane,
  memory,
  reads,
  upFor,
  waitingOn,
  warning,
} from '../../app/javascript/plain'

const base = {
  type: 'database',
  key: 'household',
  capabilities: ['storage'],
}

describe('plain words for resources', () => {
  test('a row says plainly what a resource is, and leaves defaults to its badges', () => {
    expect(does({ ...base })).toBe('Files kept inside xixo')
    expect(does({ ...base, type: 'filesystem' })).toBe('A folder')
    expect(does({ ...base, type: 'machine', key: 'local' })).toBe(
      'Where xixo runs',
    )
    expect(
      does({ ...base, type: 'openai-compatible', capabilities: ['inference'] }),
    ).toBe('A model server')
    expect(does({ ...base, type: 'mystery', capabilities: [] })).toBe(
      'A tool agents can use',
    )
  })

  test('an error reads as a sentence, and anything unknown stays general', () => {
    expect(
      humane('local: xixo link beside the server has not enrolled yet'),
    ).toBe("xixo link on this server hasn't connected yet")
    expect(humane('ECONNREFUSED 10.0.0.4:11434')).toBe(
      "It didn't answer when xixo last checked",
    )
  })

  test('what a machine reads is named in plain words', () => {
    expect(reads([], ['pdf'])).toBe('Reads nothing yet')
    expect(reads(['pdf', 'text'], [])).toBe('Reads every kind of file')
    expect(reads(['text', 'pdf', 'image', 'email'], ['media'])).toBe(
      'Reads PDFs, photos, and 2 more',
    )
  })

  test('health reads in human terms, and warns only when something runs low', () => {
    const health = {
      connected: true,
      uptime: 3 * 86400 + 5,
      memoryTotal: 16 * 1024 ** 3,
      memoryAvailable: 4 * 1024 ** 3,
      disks: [{ path: '/', total: 100 * 1024 ** 3, free: 2 * 1024 ** 3 }],
    }

    expect(upFor(health.uptime)).toBe('up 3 days')
    expect(memory(health)).toBe('4.0 GB of 16 GB memory free')
    expect(disks(health)).toEqual(['/: 2.0 GB of 100 GB free'])
    expect(warning(health)).toBe('Almost out of space on /')
    expect(warning({ ...health, disks: [] })).toBeNull()
  })
})

describe('files waiting on a machine', () => {
  test('files waiting for a model server on a machine that is asleep wait for it to come back', () => {
    expect(waitingOn([{ kind: 'models', count: 110 }], false)).toBe(
      '110 files wait for it to come back',
    )
  })

  test('files waiting for a model server on a machine that is online wait for the server to answer', () => {
    expect(waitingOn([{ kind: 'models', count: 1 }], true)).toBe(
      '1 file waits for its model server to answer',
    )
    expect(
      waitingOn(
        [
          { kind: 'models', count: 2 },
          { kind: 'pdf', count: 3 },
        ],
        true,
      ),
    ).toBe('5 files wait for it to read PDFs')
  })
})
