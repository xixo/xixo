export interface Build {
  os: string
  arch: string
  file: string
  sha256: string
}

export interface Plan {
  xixo: string
  issuer: string
  code: string
  name: string
  build: Build
  folders: string[]
  extractsForOthers: boolean
  lend: boolean
}

export interface Step {
  title: string
  detail: string
  command: string
}

export const SYSTEMS: Record<string, string> = {
  linux: 'Linux',
  darwin: 'macOS',
}

const ARCHES: Record<string, Record<string, string>> = {
  linux: { amd64: 'Intel or AMD (x86_64)', arm64: 'ARM (aarch64)' },
  darwin: { amd64: 'Intel', arm64: 'Apple silicon' },
}

export function buildLabel(build: Build) {
  return `${SYSTEMS[build.os] ?? build.os} on ${ARCHES[build.os]?.[build.arch] ?? build.arch}`
}

const UNSHAREABLE = /[\p{Cc}:"'\\]/u

export function quoted(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

export function folderLines(text: string) {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
}

export function unshareable(path: string) {
  if (!path.startsWith('/')) return `${path} is not an absolute path`
  if (UNSHAREABLE.test(path))
    return `${path} holds a colon, a quotation mark, an apostrophe, a backslash, or a control character`

  const parts = path.split('/').slice(1)
  const clean =
    path === '/' ||
    parts.every((part) => part !== '' && part !== '.' && part !== '..')

  return clean ? null : `${path} is not in its shortest form`
}

export function offered(builds: readonly Build[]) {
  return builds.filter((build) => build.os in SYSTEMS)
}

function escaped(path: string) {
  return encodeURIComponent(path).replace(
    /[!'()*]/g,
    (held) => `%${held.charCodeAt(0).toString(16).toUpperCase()}`,
  )
}

function bearer() {
  return `printf 'Authorization: Bearer %s\\n' "$code" | curl -fsS -H @-`
}

export function config(plan: Plan) {
  return JSON.stringify(
    {
      xixo: plan.xixo,
      issuer: plan.issuer,
      folders: plan.folders,
      lend: plan.lend,
      extracts_for_others: plan.extractsForOthers,
    },
    null,
    2,
  )
}

function linked(plan: Plan, program: string) {
  return [
    `client=$(printf %s "$code" | ${program} enroll --token - --name ${quoted(plan.name)}) &&`,
    `${bearer()} --data-urlencode "client_id=$client" ${quoted(`${plan.xixo}/link`)} &&`,
  ]
}

function mac(plan: Plan): Step[] {
  const download = `${plan.xixo}/link/download/${plan.build.file}`
  const plist = '"$HOME/Library/LaunchAgents/network.xixo.link.plist"'

  return [
    {
      title: 'Get xixo link',
      detail:
        'Downloads xixo link from this xixo with the code, checks that it arrived whole, and puts it in your Library.',
      command: [
        `code=${quoted(plan.code)}`,
        'dir="$HOME/Library/Application Support/xixo-link"',
        'mkdir -p "$dir/bin"',
        `${bearer()} -o xixo-link ${quoted(download)}`,
        `echo ${quoted(`${plan.build.sha256}  xixo-link`)} | shasum -a 256 -c -`,
        'install -m 0755 xixo-link "$dir/bin/xixo-link"',
        'rm xixo-link',
      ].join('\n'),
    },
    {
      title: 'Say what it shares',
      detail:
        'Writes the config and the launch agent. The config on the machine is the only place its folders are named. Change it there to change them later.',
      command: [
        `cat > "$dir/config.json" <<'EOF'`,
        config(plan),
        'EOF',
        'chmod 600 "$dir/config.json"',
        'mkdir -p "$HOME/Library/LaunchAgents"',
        `${bearer()} ${quoted(`${plan.xixo}/link/download/xixo-link.plist`)} | sed "s|@HOME@|$HOME|g" > ${plist}`,
      ].join('\n'),
    },
    {
      title: 'Link up and start',
      detail:
        'Enrolls the Mac with its own keys, tells xixo which machine it is, and starts xixo link as you. A folder in Documents, Desktop, Downloads, or iCloud Drive also needs Full Disk Access for xixo-link in System Settings.',
      command: [
        ...linked(plan, '"$dir/bin/xixo-link"'),
        `launchctl bootstrap "gui/$(id -u)" ${plist}`,
      ].join('\n'),
    },
  ]
}

export function steps(plan: Plan): Step[] {
  if (plan.build.os === 'darwin') return mac(plan)

  const download = `${plan.xixo}/link/download/${plan.build.file}`
  const unit = [
    `${plan.xixo}/link/download/xixo-link.service?user=$(id -un)`,
    ...plan.folders.map((folder) => `folders%5B%5D=${escaped(folder)}`),
  ].join('&')

  return [
    {
      title: 'Get xixo link',
      detail:
        'Downloads xixo link from this xixo with the code, checks that it arrived whole, and puts it in /usr/local/bin.',
      command: [
        `code=${quoted(plan.code)}`,
        `${bearer()} -o xixo-link ${quoted(download)}`,
        `echo ${quoted(`${plan.build.sha256}  xixo-link`)} | sha256sum -c -`,
        'sudo install -m 0755 xixo-link /usr/local/bin/xixo-link',
        'rm xixo-link',
      ].join('\n'),
    },
    {
      title: 'Say what it shares',
      detail:
        'Writes the config and the service. The config on the machine is the only place its folders are named, and the service mounts each one read-only. Change both on the machine to change them later.',
      command: [
        'sudo install -d -m 0755 /etc/xixo-link',
        "sudo tee /etc/xixo-link/config.json > /dev/null <<'EOF'",
        config(plan),
        'EOF',
        `${bearer()} "${unit}" | sudo tee /etc/systemd/system/xixo-link.service > /dev/null`,
      ].join('\n'),
    },
    {
      title: 'Link up and start',
      detail:
        'Enrolls the machine with its own keys, tells xixo which machine it is, and starts xixo link as you, the account that owns the folders.',
      command: [
        'sudo install -d -m 0700 -o "$(id -un)" -g "$(id -gn)" /var/lib/xixo-link',
        ...linked(plan, 'xixo-link'),
        'sudo systemctl daemon-reload && sudo systemctl enable --now xixo-link',
      ].join('\n'),
    },
  ]
}
