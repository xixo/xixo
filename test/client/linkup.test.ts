import { describe, expect, test } from 'vitest'
import {
  config,
  folderLines,
  offered,
  quoted,
  steps,
  unshareable,
} from '../../app/javascript/linkup'

const plan = {
  xixo: 'https://xixo.example.com',
  issuer: 'https://id.example.com',
  code: 'enroll-abc_123',
  name: "jon's studio",
  build: {
    os: 'linux',
    arch: 'arm64',
    file: 'xixo-agent-linux-arm64',
    sha256: 'f'.repeat(64),
  },
  folders: ['/srv/media', '/data/My Photos!'],
  extractsForOthers: true,
  lend: false,
}

describe('linking up a machine', () => {
  test('the code reaches curl and the agent on standard input, never as an argument', () => {
    const all = steps(plan)
      .map((step) => step.command)
      .join('\n')

    expect(all).toContain("code='enroll-abc_123'")
    expect(all.match(/enroll-abc_123/g)).toHaveLength(1)
    expect(all).toContain(
      `printf 'Authorization: Bearer %s\\n' "$code" | curl -fsS -H @-`,
    )
    expect(all).toContain(
      `printf %s "$code" | xixo-agent enroll --token - --name 'jon'\\''s studio'`,
    )
    expect(all).not.toContain('curl -fsSL')
  })

  test('the download is checked against its digest before it is installed', () => {
    const [get] = steps(plan)

    expect(get.command).toContain(
      "'https://xixo.example.com/agent/download/xixo-agent-linux-arm64'",
    )
    expect(get.command).toContain(
      `echo '${'f'.repeat(64)}  xixo-agent' | sha256sum -c -`,
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
    })
    expect(shares.command).toContain(
      '"https://xixo.example.com/agent/download/xixo-agent.service?user=$(id -un)&folders%5B%5D=%2Fsrv%2Fmedia&folders%5B%5D=%2Fdata%2FMy%20Photos%21"',
    )
  })

  test('linking comes before the agent starts, so its first connection is known', () => {
    const [, , last] = steps(plan)
    const lines = last.command.split('\n')

    expect(
      lines.findIndex((line) => line.includes('/agent/link')),
    ).toBeLessThan(
      lines.findIndex((line) => line.includes('systemctl enable --now')),
    )
  })

  test('a folder the agent cannot share is named', () => {
    expect(folderLines(' /srv/media \n\n/data\n')).toEqual([
      '/srv/media',
      '/data',
    ])
    expect(unshareable('/srv/media')).toBeNull()
    expect(unshareable('srv')).toMatch(/not an absolute path/)
    expect(unshareable('/srv/../etc')).toMatch(/shortest form/)
    expect(unshareable('/srv/media/')).toMatch(/shortest form/)
    expect(unshareable('/srv/a:b')).toMatch(/colon/)
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

  test('a Mac gets the agent in its Library and starts it as a launch agent', () => {
    const [get, shares, last] = steps({
      ...plan,
      build: { ...plan.build, os: 'darwin', file: 'xixo-agent-darwin-arm64' },
    })

    expect(get.command).toContain('shasum -a 256 -c -')
    expect(get.command).toContain(
      'install -m 0755 xixo-agent "$dir/bin/xixo-agent"',
    )
    expect(shares.command).toContain('cat > "$dir/config.json"')
    expect(shares.command).toContain(
      `'https://xixo.example.com/agent/download/xixo-agent.plist' | sed "s|@HOME@|$HOME|g"`,
    )
    expect(last.command).toContain('"$dir/bin/xixo-agent" enroll --token -')
    expect(last.command).toContain('launchctl bootstrap "gui/$(id -u)"')
    expect(last.command).not.toContain('sudo')
  })
})
