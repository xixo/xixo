import { describe, expect, test } from 'vitest'
import {
  familyOf,
  hrefFor,
  lookOf,
  pluralOf,
  shortOf,
  TYPE,
} from '../../app/javascript/looks'

describe('familyOf', () => {
  test('names the family an analyzer would read the bytes as', () => {
    expect(familyOf('application/pdf')).toBe('pdf')
    expect(familyOf('message/rfc822')).toBe('email')
    expect(familyOf('image/heic')).toBe('image')
    expect(familyOf('text/csv')).toBe('data')
    expect(familyOf('text/markdown')).toBe('text')
    expect(familyOf('xixo/page')).toBe('page')
    expect(
      familyOf(
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
    ).toBe('xlsx')
  })

  test('falls back to a plain file for what it does not know or was not told', () => {
    expect(familyOf('application/octet-stream')).toBe('file')
    expect(familyOf(null)).toBe('file')
  })
})

describe('lookOf', () => {
  test('a file looks like the family of its bytes', () => {
    expect(lookOf({ type: TYPE.file, mime: 'application/pdf' })).toMatchObject({
      tone: 'var(--k-pdf)',
      label: 'pdf',
    })
  })

  test('the other types look like what they are, whatever mime they carry', () => {
    expect(lookOf({ type: TYPE.tag, mime: 'text/plain' }).label).toBe('tag')
    expect(lookOf({ type: TYPE.address }).tone).toBe('var(--brass)')
    expect(lookOf({ type: TYPE.mime }).label).toBe('content type')
    expect(lookOf({ type: TYPE.note }).label).toBe('note')
  })
})

describe('naming a type', () => {
  test('the short name in a link maps to the full type and back', () => {
    expect(shortOf('xixo:tag')).toBe('tag')
    expect(shortOf('xixo:nonsense')).toBeNull()
    expect(pluralOf(TYPE.mime)).toBe('content types')
  })

  test('a feed is reached at its address, and everything else by id', () => {
    expect(hrefFor({ id: '9', type: TYPE.address, key: '/buy' })).toBe('/buy')
    expect(hrefFor({ id: '9', type: TYPE.tag, key: 'receipts' })).toBe(
      '/items/9',
    )
  })
})
