export interface Build {
  os: string
  arch: string
  file: string
  sha256: string
}

export interface Shared {
  path: string
  writable: boolean
}

export interface Plan {
  xixo: string
  issuer: string
  name: string
  build: Build
  macReader?: string | null
  packages?: string[]
  programs?: boolean
  folders: Shared[]
  tools: string[]
  extractsForOthers: boolean
  lend: boolean
}

export interface Tool {
  name: string
  label: string
  description: string
}

export const TOOLS: Tool[] = [
  {
    name: 'browse',
    label: 'Browse',
    description: 'List the files in its folders.',
  },
  {
    name: 'search',
    label: 'Search',
    description: 'Find files by name, path, and the text drawn out of them.',
  },
  {
    name: 'read',
    label: 'Read',
    description:
      'Read a file as text. Without whole files, the text xixo drew out.',
  },
  {
    name: 'extract',
    label: 'Extract',
    description: "Run the machine's own readers on a file.",
  },
  {
    name: 'write',
    label: 'Write',
    description: 'Write files into a folder that ends in :rw.',
  },
  {
    name: 'models',
    label: 'Models',
    description: 'Ask a model server on the machine, such as Ollama.',
  },
]

export const STANDARD_TOOLS = ['browse', 'search', 'read', 'extract']

const WRITABLE = ':rw'

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

export function sharedFolders(text: string): Shared[] {
  return folderLines(text).map((line) =>
    line.endsWith(WRITABLE)
      ? { path: line.slice(0, -WRITABLE.length), writable: true }
      : { path: line, writable: false },
  )
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

const ASKED = ["printf 'Paste the code xixo shows: '", 'read -rs code', 'echo']

export function config(plan: Plan) {
  return JSON.stringify(
    {
      xixo: plan.xixo,
      issuer: plan.issuer,
      folders: plan.folders.map((folder) =>
        folder.writable ? { path: folder.path, writable: true } : folder.path,
      ),
      lend: plan.lend,
      extracts_for_others: plan.extractsForOthers,
      tools: TOOLS.map((tool) => tool.name).filter((name) =>
        plan.tools.includes(name),
      ),
    },
    null,
    2,
  )
}

function linked(plan: Plan, program: string) {
  return [
    `printf %s "$code" | ${program} enroll --token - --name ${quoted(plan.name)} > /dev/null &&`,
    `printf %s "$code" | ${program} link --code - &&`,
  ]
}

function macReader(plan: Plan) {
  if (!plan.macReader) return []

  return [
    `reader=${quoted(plan.macReader)}`,
    'if curl -fsS --location --proto =https -o xixo-mac-reader "$reader" &&',
    '  curl -fsS --location --proto =https -o xixo-mac-reader.sha256 "$reader.sha256" &&',
    '  shasum -a 256 -c xixo-mac-reader.sha256; then',
    '  install -m 0755 xixo-mac-reader "$dir/bin/xixo-mac-reader"',
    'else',
    `  echo 'No mac reader came with this release, so this Mac reads files with the Homebrew programs it has.'`,
    'fi',
    'rm -f xixo-mac-reader xixo-mac-reader.sha256',
  ]
}

function mac(plan: Plan): Step[] {
  const download = `${plan.xixo}/link/download/${plan.build.file}`
  const plist = '"$HOME/Library/LaunchAgents/network.xixo.link.plist"'

  return [
    {
      title: 'Get xixo link',
      detail:
        "Asks for the code, which stays out of your shell's history, then downloads xixo link from this xixo with it, checks that it arrived whole, and puts it in your Library. Beside it goes the mac reader from this version's GitHub release, checked against the SHA-256 published with it, which reads PDFs, images, audio, and video with what macOS ships.",
      command: [
        ...ASKED,
        'dir="$HOME/Library/Application Support/xixo-link"',
        'mkdir -p "$dir/bin"',
        `${bearer()} -o xixo-link ${quoted(download)}`,
        `echo ${quoted(`${plan.build.sha256}  xixo-link`)} | shasum -a 256 -c -`,
        'install -m 0755 xixo-link "$dir/bin/xixo-link"',
        'rm xixo-link',
        ...macReader(plan),
      ].join('\n'),
    },
    {
      title: 'Say what it shares',
      detail:
        'Writes the config and the launch agent. The config on the machine is the only place its folders and tools are named. Change it there to change them later.',
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
        'Enrolls the Mac with its own keys, has xixo link tell xixo which machine it is with the code and its own token, and starts xixo link as you. A folder in Documents, Desktop, Downloads, or iCloud Drive also needs Full Disk Access for xixo-link in System Settings.',
      command: [
        ...linked(plan, '"$dir/bin/xixo-link"'),
        `launchctl bootstrap "gui/$(id -u)" ${plist}`,
        'unset code',
      ].join('\n'),
    },
  ]
}

function readers(plan: Plan): Step[] {
  if (!plan.programs || !plan.packages?.length) return []

  const apt = 'sudo env DEBIAN_FRONTEND=noninteractive apt-get'

  return [
    {
      title: 'Install the readers',
      detail:
        'Installs the programs that read PDFs, images, audio, video, and office documents, with apt on Debian or Ubuntu. On another system, install them with its own package manager.',
      command: [
        'if command -v apt-get > /dev/null; then',
        `  ${apt} update -qq && ${apt} install -y --no-install-recommends ${plan.packages.join(' ')}`,
        'else',
        "  echo 'This system has no apt, so install the readers with its own package manager.'",
        'fi',
      ].join('\n'),
    },
  ]
}

export function steps(plan: Plan): Step[] {
  if (plan.build.os === 'darwin') return mac(plan)

  const download = `${plan.xixo}/link/download/${plan.build.file}`
  const unit = [
    `${plan.xixo}/link/download/xixo-link.service?user=$(id -un)`,
    ...plan.folders.map(
      (folder) =>
        `folders%5B%5D=${escaped(folder.writable ? `${folder.path}${WRITABLE}` : folder.path)}`,
    ),
  ].join('&')

  return [
    {
      title: 'Get xixo link',
      detail:
        "Asks for the code, which stays out of your shell's history, then downloads xixo link from this xixo with it, checks that it arrived whole, and puts it in /usr/local/bin.",
      command: [
        ...ASKED,
        `${bearer()} -o xixo-link ${quoted(download)}`,
        `echo ${quoted(`${plan.build.sha256}  xixo-link`)} | sha256sum -c -`,
        'sudo install -m 0755 xixo-link /usr/local/bin/xixo-link',
        'rm xixo-link',
      ].join('\n'),
    },
    {
      title: 'Say what it shares',
      detail:
        'Writes the config and the service. The config on the machine is the only place its folders and tools are named, and the service mounts each folder read-only, or read-write when it ends in :rw. Change both on the machine to change them later.',
      command: [
        'sudo install -d -m 0755 /etc/xixo-link',
        "sudo tee /etc/xixo-link/config.json > /dev/null <<'EOF'",
        config(plan),
        'EOF',
        `${bearer()} "${unit}" | sudo tee /etc/systemd/system/xixo-link.service > /dev/null`,
      ].join('\n'),
    },
    ...readers(plan),
    {
      title: 'Link up and start',
      detail:
        'Enrolls the machine with its own keys, has xixo link tell xixo which machine it is with the code and its own token, and starts xixo link as you, the account that owns the folders.',
      command: [
        'sudo install -d -m 0700 -o "$(id -un)" -g "$(id -gn)" /var/lib/xixo-link',
        ...linked(plan, 'xixo-link'),
        'sudo systemctl daemon-reload && sudo systemctl enable --now xixo-link',
        'unset code',
      ].join('\n'),
    },
  ]
}
