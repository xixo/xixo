import { describe, expect, test } from 'vitest'
import {
  disks,
  does,
  humane,
  memory,
  reads,
  upFor,
  warning,
} from '../../app/javascript/plain'

const base = {
  type: 'database',
  key: 'household',
  via: null,
  capabilities: ['storage'],
  defaultStorage: false,
  defaultInference: false,
}

describe('plain words for resources', () => {
  test('a card says what a resource does for the person', () => {
    expect(does({ ...base, defaultStorage: true })).toBe(
      'A folder on this server, where your uploads go',
    )
    expect(does({ ...base, type: 'filesystem', via: 'studio' })).toBe(
      'A folder on studio',
    )
    expect(does({ ...base, type: 'machine', key: 'local' })).toBe(
      'The machine xixo runs on',
    )
    expect(
      does({
        ...base,
        type: 'openai-compatible',
        capabilities: ['inference'],
        defaultInference: true,
      }),
    ).toBe('A model server, which answers your questions')
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
