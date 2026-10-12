import { describe, expect, test } from 'vitest'
import {
  config,
  folderLines,
  offered,
  quoted,
  STANDARD_TOOLS,
  sharedFolders,
  steps,
  unshareable,
} from '../../app/javascript/linkup'

const plan = {
  xixo: 'https://xixo.example.com',
  issuer: 'https://id.example.com',
  name: "jon's studio",
  build: {
    os: 'linux',
    arch: 'arm64',
    file: 'xixo-link-linux-arm64',
    sha256: 'f'.repeat(64),
  },
  folders: [
    { path: '/srv/media', writable: false },
    { path: '/data/My Photos!', writable: false },
  ],
  tools: STANDARD_TOOLS,
  extractsForOthers: true,
  lend: false,
}

describe('linking up a machine', () => {
  test('the code is read from the terminal and reaches curl and xixo link on standard input, never as an argument', () => {
    const all = steps(plan)
      .map((step) => step.command)
      .join('\n')

    expect(all).toContain('read -rs code')
    expect(all).not.toContain('code=')
    expect(all).toContain(
      `printf 'Authorization: Bearer %s\\n' "$code" | curl -fsS -H @-`,
    )
    expect(all).toContain(
      `printf %s "$code" | xixo-link enroll --token - --name 'jon'\\''s studio' > /dev/null &&`,
    )
    expect(all).toContain(`printf %s "$code" | xixo-link link --code - &&`)
    expect(all).not.toContain('client_id')
    expect(all.trimEnd().endsWith('unset code')).toBe(true)
    for (const line of all.split('\n').filter((held) => held.includes('$code')))
      expect(line).not.toMatch(/ -L|--location/)
  })

  test('the download is checked against its digest before it is installed', () => {
    const [get] = steps(plan)

    expect(get.command).toContain(
      "'https://xixo.example.com/link/download/xixo-link-linux-arm64'",
    )
    expect(get.command).toContain(
      `echo '${'f'.repeat(64)}  xixo-link' | sha256sum -c -`,
    )
  })

  test('the config names the folders, and the service is asked for with the same ones', () => {
    const [, shares] = steps(plan)

    expect(JSON.parse(config(plan))).toEqual({
      xixo: 'https://xixo.example.com',
      issuer: 'https://id.example.com',
      folders: ['/srv/media', '/data/My Photos!'],
      lend: false,
      extracts_for_others: true,
      tools: ['browse', 'search', 'read', 'extract'],
    })
    expect(shares.command).toContain(
      '"https://xixo.example.com/link/download/xixo-link.service?user=$(id -un)&folders%5B%5D=%2Fsrv%2Fmedia&folders%5B%5D=%2Fdata%2FMy%20Photos%21"',
    )
  })

  test('a folder ending in :rw is shared writable in the config and the service, and the tools chosen are written', () => {
    const writable = {
      ...plan,
      folders: sharedFolders('/srv/media\n/srv/inbox:rw'),
      tools: ['write', 'browse', 'models'],
    }
    const [, shares] = steps(writable)

    expect(JSON.parse(config(writable))).toMatchObject({
      folders: ['/srv/media', { path: '/srv/inbox', writable: true }],
      tools: ['browse', 'write', 'models'],
    })
    expect(shares.command).toContain(
      'folders%5B%5D=%2Fsrv%2Fmedia&folders%5B%5D=%2Fsrv%2Finbox%3Arw"',
    )
  })

  test('linking comes before xixo link starts, so its first connection is known', () => {
    const [, , last] = steps(plan)
    const lines = last.command.split('\n')

    expect(lines.findIndex((line) => line.includes('/link'))).toBeLessThan(
      lines.findIndex((line) => line.includes('systemctl enable --now')),
    )
  })

  test('a folder xixo link cannot share is named', () => {
    expect(folderLines(' /srv/media \n\n/data\n')).toEqual([
      '/srv/media',
      '/data',
    ])
    expect(unshareable('/srv/media')).toBeNull()
    expect(unshareable('srv')).toMatch(/not an absolute path/)
    expect(unshareable('/srv/../etc')).toMatch(/shortest form/)
    expect(unshareable('/srv/media/')).toMatch(/shortest form/)
    expect(unshareable('/srv/a:b')).toMatch(/colon/)
    expect(sharedFolders('/srv/inbox:rw\n/srv/a:b')).toEqual([
      { path: '/srv/inbox', writable: true },
      { path: '/srv/a:b', writable: false },
    ])
  })

  test('only systems the commands are written for are offered', () => {
    expect(
      offered([
        { os: 'linux', arch: 'amd64', file: 'a', sha256: '' },
        { os: 'plan9', arch: 'amd64', file: 'b', sha256: '' },
        { os: 'darwin', arch: 'arm64', file: 'c', sha256: '' },
      ]).map((build) => build.file),
    ).toEqual(['a', 'c'])
    expect(quoted("it's")).toBe(`'it'\\''s'`)
  })

  test('a Mac gets xixo link in its Library and starts it as a launch agent', () => {
    const [get, shares, last] = steps({
      ...plan,
      build: { ...plan.build, os: 'darwin', file: 'xixo-link-darwin-arm64' },
    })

    expect(get.command).toContain('shasum -a 256 -c -')
    expect(get.command).toContain(
      'install -m 0755 xixo-link "$dir/bin/xixo-link"',
    )
    expect(shares.command).toContain('cat > "$dir/config.json"')
    expect(shares.command).toContain(
      `'https://xixo.example.com/link/download/xixo-link.plist' | sed "s|@HOME@|$HOME|g"`,
    )
    expect(last.command).toContain('"$dir/bin/xixo-link" enroll --token -')
    expect(last.command).toContain('launchctl bootstrap "gui/$(id -u)"')
    expect(last.command).not.toContain('sudo')
    expect(get.command).not.toContain('xixo-mac-reader')
  })

  test('a Mac gets the mac reader of the server release, checked against the SHA-256 published with it', () => {
    const reader =
      'https://github.com/xixo/xixo/releases/download/server-v0.2.0/xixo-mac-reader'
    const [get] = steps({
      ...plan,
      macReader: reader,
      build: { ...plan.build, os: 'darwin', file: 'xixo-link-darwin-arm64' },
    })
    const lines = get.command.split('\n')

    expect(get.command).toContain(`reader='${reader}'`)
    expect(get.command).toContain('"$reader.sha256"')
    expect(get.command).toContain('shasum -a 256 -c xixo-mac-reader.sha256')
    expect(
      lines.findIndex((line) => line.includes('shasum -a 256 -c xixo-mac')),
    ).toBeLessThan(
      lines.findIndex((line) => line.includes('"$dir/bin/xixo-mac-reader"')),
    )
    expect(
      lines.filter((line) => line.includes('$reader')).join('\n'),
    ).not.toContain('Authorization')
  })
})
