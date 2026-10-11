import { describe, expect, test } from 'vitest'
import { type Happening, sorted, worst } from '../../app/javascript/activity'

let next = 100

function event(held: Partial<Happening> = {}): Happening {
  next -= 1

  return {
    id: String(next),
    actor: 'agent',
    channel: 'mcp',
    action: 'connect',
    status: 'ok',
    arguments: {},
    createdAt: '2026-09-21T23:00:00Z',
    ...held,
  }
}

const run = (id: string, cause = 'upload') => ({ id, cause })
const image = { id: '19', key: 'image.png', title: null }

describe('sorted', () => {
  test('folds one analysis into one run, oldest step first', () => {
    const connect = event({
      analysis: run('7'),
      workingOn: image,
      told: 'filed image.png under image',
    })
    const read = event({
      analysis: run('7'),
      workingOn: image,
      action: 'feed',
      told: 'read image.png',
    })

    const [entry, ...rest] = sorted([connect, read])

    expect(rest).toEqual([])
    expect(entry.kind).toBe('run')
    if (entry.kind !== 'run') return

    expect(entry.feed).toEqual(image)
    expect(entry.lines.map((line) => line.event.told)).toEqual([
      'read image.png',
      'filed image.png under image',
    ])
  })

  test('keeps two analyses that interleave apart', () => {
    const entries = sorted([
      event({ analysis: run('1'), told: 'a' }),
      event({ analysis: run('2'), told: 'b' }),
      event({ analysis: run('1'), told: 'c' }),
    ])

    expect(entries.map((entry) => entry.key)).toEqual(['run:1', 'run:2'])
  })

  test('collapses the same refusal repeated into one line', () => {
    const refused = {
      actor: 'nobody',
      channel: 'graphql',
      action: 'authorize',
      status: 'denied',
      detail: 'invalid_token',
      remoteIp: '10.0.0.1',
    }
    const entries = sorted([
      event(refused),
      event(refused),
      event(refused),
      event({ actor: 'person', actorName: 'Jon' }),
    ])

    expect(entries).toHaveLength(2)
    expect(entries[0].kind === 'one' && entries[0].line.times).toBe(3)
  })

  test('joins a run that a second page continues', () => {
    const first = [event({ analysis: run('3'), told: 'later' })]
    const second = [event({ analysis: run('3'), told: 'earlier' })]

    const entries = sorted([...first, ...second])

    expect(entries).toHaveLength(1)
    expect(
      entries[0].kind === 'run' &&
        entries[0].lines.map((line) => line.event.told),
    ).toEqual(['earlier', 'later'])
  })
})

describe('worst', () => {
  test('ranks a failure over a refusal over success', () => {
    expect(worst(['ok', 'denied', 'ok'])).toBe('denied')
    expect(worst(['denied', 'error'])).toBe('error')
    expect(worst([])).toBe('ok')
  })
})
