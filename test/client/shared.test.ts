import { describe, expect, test } from 'vitest'
import { toldOfShare } from '../../app/javascript/shared'

const told = (query: string) => toldOfShare(new URLSearchParams(query))

describe('toldOfShare', () => {
  test('says nothing when nothing was shared', () => {
    expect(told('')).toBeNull()
    expect(told('q=march')).toBeNull()
    expect(told('shared=whatever')).toBeNull()
  })

  test('names one kept file, note, page, and download', () => {
    expect(told('shared=kept')?.text).toMatch(/file is kept/)
    expect(told('shared=note')?.text).toMatch(/note is kept/)
    expect(told('shared=page')?.text).toMatch(/being rendered/)
    expect(told('shared=download')?.text).toMatch(/being fetched/)
  })

  test('counts several files by what became of them', () => {
    expect(told('shared=files&kept=2&twins=1&refused=1')).toEqual({
      text: 'Shared to xixo: 2 files kept, 1 file already here, 1 file with nowhere to go.',
      wrong: false,
    })
  })

  test('marks a share where every file was refused as wrong', () => {
    expect(told('shared=files&refused=3')?.wrong).toBe(true)
  })

  test('reads only counts from the address, never text', () => {
    expect(told('shared=files&kept=<b>x</b>')?.text).toBe(
      'Nothing came with that share.',
    )
    expect(told('shared=files&kept=-4')?.text).toBe(
      'Nothing came with that share.',
    )
  })

  test('tells a refused or denied share as wrong', () => {
    expect(told('shared=refused')?.wrong).toBe(true)
    expect(told('shared=denied')?.wrong).toBe(true)
    expect(told('shared=nothing')?.wrong).toBe(true)
  })
})
