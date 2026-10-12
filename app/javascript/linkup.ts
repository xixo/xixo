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

export const SYSTEMS: Record<string, string> = { linux: 'Linux' }

export const ARCHES: Record<string, string> = {
  amd64: 'Intel or AMD (x86_64)',
  arm64: 'ARM (aarch64)',
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

export function steps(plan: Plan): Step[] {
  const download = `${plan.xixo}/agent/download/${plan.build.file}`
  const unit = [
    `${plan.xixo}/agent/download/xixo-agent.service?user=$(id -un)`,
    ...plan.folders.map((folder) => `folders%5B%5D=${escaped(folder)}`),
  ].join('&')

  return [
    {
      title: 'Get the agent',
      detail:
        'Downloads the agent from this xixo with the code, checks that it arrived whole, and puts it in /usr/local/bin.',
      command: [
        `code=${quoted(plan.code)}`,
        `${bearer()} -o xixo-agent ${quoted(download)}`,
        `echo ${quoted(`${plan.build.sha256}  xixo-agent`)} | sha256sum -c -`,
        'sudo install -m 0755 xixo-agent /usr/local/bin/xixo-agent',
        'rm xixo-agent',
      ].join('\n'),
    },
    {
      title: 'Say what it shares',
      detail:
        'Writes the config and the service. The config on the machine is the only place its folders are named, and the service mounts each one read-only. Change both on the machine to change them later.',
      command: [
        'sudo install -d -m 0755 /etc/xixo-agent',
        "sudo tee /etc/xixo-agent/config.json > /dev/null <<'EOF'",
        config(plan),
        'EOF',
        `${bearer()} "${unit}" | sudo tee /etc/systemd/system/xixo-agent.service > /dev/null`,
      ].join('\n'),
    },
    {
      title: 'Link up and start',
      detail:
        'Enrolls the machine with its own keys, tells xixo which machine it is, and starts the agent as you, the account that owns the folders.',
      command: [
        'sudo install -d -m 0700 -o "$(id -un)" -g "$(id -gn)" /var/lib/xixo-agent',
        `client=$(printf %s "$code" | xixo-agent enroll --token - --name ${quoted(plan.name)}) &&`,
        `${bearer()} --data-urlencode "client_id=$client" ${quoted(`${plan.xixo}/agent/link`)} &&`,
        'sudo systemctl daemon-reload && sudo systemctl enable --now xixo-agent',
      ].join('\n'),
    },
  ]
}
