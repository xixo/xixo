import { describe, expect, it } from 'vitest'
import { amount, movedSoFar, share } from '../../app/javascript/moving'

describe('a move in progress', () => {
  it('says how many files and how many bytes have moved', () => {
    const moved = {
      files: 15912,
      filesDone: 1204,
      filesFailed: 0,
      bytes: String(55 * 1024 ** 3),
      bytesDone: String(4.1 * 1024 ** 3),
    }

    expect(movedSoFar(moved)).toBe(
      '1,204 of 15,912 files moved, 4.1 GB of 55 GB.',
    )
    expect(Math.round(share(moved))).toBe(7)
  })

  it('names the files that stayed where they were', () => {
    expect(
      movedSoFar({
        files: 3,
        filesDone: 2,
        filesFailed: 1,
        bytes: 300,
        bytesDone: 200,
      }),
    ).toBe('2 of 3 files moved, 200 bytes of 300 bytes. 1 stayed where it was.')
  })

  it('waits for the files before it counts them', () => {
    expect(movedSoFar(null)).toBe('Looking for the files to move.')
    expect(share(null)).toBe(0)
  })

  it('writes sizes in the unit that fits', () => {
    expect(amount(1)).toBe('1 byte')
    expect(amount(1536)).toBe('1.5 KB')
    expect(amount(20 * 1024 ** 2)).toBe('20 MB')
  })
})
