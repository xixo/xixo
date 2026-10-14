import { describe, expect, test } from 'vitest'
import {
  argument,
  command,
  detected,
  folderList,
  quoted,
  sharing,
} from '../../app/javascript/linkup'

describe('linking up a machine', () => {
  test('the command is one line, with the folders after it', () => {
    expect(command('https://xixo.example.com', [])).toBe(
      'curl -fsSL https://xixo.example.com/link.sh | sh',
    )
    expect(
      command('https://xixo.example.com', ['~/Documents', '/srv/media:rw']),
    ).toBe(
      'curl -fsSL https://xixo.example.com/link.sh | sh -s -- ~/Documents /srv/media:rw',
    )
  })

  test('a folder with spaces or quotes is quoted, and a home folder still expands', () => {
    expect(argument('/data/My Photos')).toBe("'/data/My Photos'")
    expect(argument('~/My Files')).toBe("~/'My Files'")
    expect(argument("/srv/jon's")).toBe(`'/srv/jon'\\''s'`)
    expect(argument('~/$(reboot)')).toBe("~/'$(reboot)'")
    expect(quoted("a'b")).toBe(`'a'\\''b'`)
  })

  test('folders are read back from what someone types, quotes and all', () => {
    expect(folderList(` ~/Documents  '/data/My Photos' "/srv/a b" `)).toEqual([
      '~/Documents',
      '/data/My Photos',
      '/srv/a b',
    ])
  })

  test('the folders a machine may write into say so', () => {
    expect(sharing([])).toBe('Shares no folders yet.')
    expect(sharing(['~/Documents'])).toBe('Shares ~/Documents.')
    expect(sharing(['~/Documents', '~/Desktop-Backup:rw'])).toBe(
      'Shares ~/Documents and ~/Desktop-Backup (read and write).',
    )
    expect(sharing(['/srv/a', '/srv/b', '/srv/inbox:rw'])).toBe(
      'Shares /srv/a, /srv/b, and /srv/inbox (read and write).',
    )
  })

  test('the system comes from the browser, among the ones this server serves', () => {
    const mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)'
    const linux = 'Mozilla/5.0 (X11; Linux x86_64)'

    expect(detected(['darwin', 'linux'], mac)).toBe('darwin')
    expect(detected(['darwin', 'linux'], linux)).toBe('linux')
    expect(detected(['linux'], mac)).toBe('linux')
  })
})
