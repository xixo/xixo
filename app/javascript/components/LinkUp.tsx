import {
  Alert,
  Button,
  Checkbox,
  Code,
  CopyButton,
  Modal,
  Select,
  Stack,
  Text,
  Textarea,
  TextInput,
} from '@mantine/core'
import {
  IconCircleCheck,
  IconFileText,
  IconFolders,
  IconLink,
  IconSparkles,
  IconTerminal2,
  IconWand,
} from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import { LinkMachineDocument, MachineChangedDocument } from 'xixo'
import { useMutation, useSubscription } from 'xixo/react'
import {
  type Build,
  buildLabel,
  folderLines,
  offered,
  steps,
  unshareable,
} from '../linkup'

export interface LinkUpInfo {
  xixo: string
  issuer: string
  builds: Build[]
}

export interface Machine {
  id: string
  key: string
  name?: string | null
}

function plural(count: number, one: string, many = `${one}s`) {
  return `${count} ${count === 1 ? one : many}`
}

export function LinkUpPanel({
  administrator,
  onLinkUp,
}: {
  administrator: boolean
  onLinkUp: () => void
}) {
  return (
    <section className="linkup" aria-labelledby="linkup-title">
      <div className="linkup-lead">
        <h3 id="linkup-title" className="linkup-title">
          Link up a machine
        </h3>
        <p className="linkup-says">
          Put the xixo agent on another computer. Its files stay where they are.
        </p>
      </div>

      <ul className="linkup-gives">
        <li>
          <IconFolders size={18} stroke={1.7} />
          Its folders become searchable
        </li>
        <li>
          <IconFileText size={18} stroke={1.7} />
          It helps read files
        </li>
        <li>
          <IconSparkles size={18} stroke={1.7} />
          Its models can answer
        </li>
      </ul>

      <div className="linkup-go">
        {administrator ? (
          <Button
            radius="xl"
            color="brand"
            size="md"
            leftSection={<IconLink size={17} stroke={2} />}
            onClick={onLinkUp}
          >
            Link up
          </Button>
        ) : (
          <Text size="sm" c="dimmed">
            An administrator links machines.
          </Text>
        )}
      </div>
    </section>
  )
}

interface Minted {
  id: string
  key: string
  code: string
  expiresAt: string
}

export function LinkUpDialog({
  info,
  relinking,
  onClose,
  onChanged,
  onSsh,
}: {
  info?: LinkUpInfo | null
  relinking?: Machine | null
  onClose: () => void
  onChanged: () => void
  onSsh: () => void
}) {
  const [way, setWay] = useState<'self' | 'ssh'>('self')
  const [name, setName] = useState('')
  const [code, setCode] = useState<Minted | null>(null)
  const [refused, setRefused] = useState<string | null>(null)
  const link = useMutation(LinkMachineDocument)

  const ask = async (variables: { key?: string; id?: string }) => {
    setRefused(null)

    const { data, error } = await link.attempt(variables)
    const answered = data?.linkMachine

    if (!answered) {
      setRefused(error?.message ?? 'That machine could not be linked.')
      return
    }

    setCode({
      id: answered.resource.id,
      key: answered.resource.key,
      code: answered.code,
      expiresAt: answered.expiresAt,
    })
    onChanged()
  }

  return (
    <Modal
      opened
      onClose={onClose}
      title={
        relinking
          ? `Link ${relinking.name || relinking.key} up again`
          : 'Link up a machine'
      }
      size="xl"
      padding="var(--s5)"
    >
      {code ? (
        <Commands
          info={info}
          code={code}
          busy={link.loading}
          onFresh={() => ask({ id: code.id })}
          onChanged={onChanged}
          onClose={onClose}
        />
      ) : relinking ? (
        <Stack gap="var(--s4)" align="flex-start">
          <Text>
            xixo makes a fresh code and shows the commands again. The machine
            keeps its current link until the new one links up.
          </Text>
          {refused && <Alert color="red">{refused}</Alert>}
          <Button
            radius="xl"
            color="brand"
            loading={link.loading}
            onClick={() => ask({ id: relinking.id })}
          >
            Get a code
          </Button>
        </Stack>
      ) : (
        <Stack gap="var(--s5)">
          <div className="linkup-ways">
            <button
              type="button"
              aria-pressed={way === 'self'}
              className="linkup-way"
              data-on={way === 'self'}
              onClick={() => setWay('self')}
            >
              <IconTerminal2 size={22} stroke={1.6} />
              <span className="linkup-way-name">Install it yourself</span>
              <span className="linkup-way-says">
                Copy a few commands into a terminal on the machine. xixo fills
                them in and waits for it to link up.
              </span>
            </button>
            <button
              type="button"
              aria-pressed={way === 'ssh'}
              className="linkup-way"
              data-on={way === 'ssh'}
              onClick={() => setWay('ssh')}
            >
              <IconWand size={22} stroke={1.6} />
              <span className="linkup-way-name">Let xixo install it</span>
              <span className="linkup-way-says">
                For a Linux machine xixo can reach over SSH. xixo signs in once,
                installs it, and forgets the key.
              </span>
            </button>
          </div>

          {way === 'self' ? (
            <form
              onSubmit={(event) => {
                event.preventDefault()
                if (name.trim()) void ask({ key: name.trim() })
              }}
            >
              <Stack gap="var(--s3)">
                <TextInput
                  size="md"
                  label="Name the machine"
                  description="How it shows in xixo, such as nas or studio. It cannot be changed later."
                  placeholder="studio"
                  autoFocus
                  withAsterisk
                  value={name}
                  onChange={(event) => setName(event.currentTarget.value)}
                />
                {refused && <Alert color="red">{refused}</Alert>}
                <div className="linkup-actions">
                  <Button
                    type="submit"
                    size="md"
                    radius="xl"
                    color="brand"
                    loading={link.loading}
                    disabled={!name.trim() || !info}
                  >
                    Show the commands
                  </Button>
                </div>
                {!info && (
                  <Text size="sm" c="dimmed">
                    Only an administrator links machines.
                  </Text>
                )}
              </Stack>
            </form>
          ) : (
            <div className="linkup-actions">
              <Button size="md" radius="xl" color="brand" onClick={onSsh}>
                Set it up over SSH
              </Button>
            </div>
          )}
        </Stack>
      )}
    </Modal>
  )
}

function useCountdown(until: string) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const ticking = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(ticking)
  }, [])

  return Math.max(0, Math.floor((Date.parse(until) - now) / 1000))
}

function Commands({
  info,
  code,
  busy,
  onFresh,
  onChanged,
  onClose,
}: {
  info?: LinkUpInfo | null
  code: Minted
  busy: boolean
  onFresh: () => void
  onChanged: () => void
  onClose: () => void
}) {
  const builds = offered(info?.builds ?? [])
  const [file, setFile] = useState(builds[0]?.file ?? '')
  const [folders, setFolders] = useState('')
  const [extractsForOthers, setExtractsForOthers] = useState(false)
  const [lend, setLend] = useState(false)
  const left = useCountdown(code.expiresAt)
  const { data } = useSubscription(MachineChangedDocument, { id: code.id })
  const heard = data?.machineChanged?.resource.machine

  useEffect(() => {
    if (heard) onChanged()
  }, [heard, onChanged])

  const build = builds.find((held) => held.file === file) ?? builds[0]
  const typed = folderLines(folders)
  const problems = typed
    .map(unshareable)
    .filter((held): held is string => held !== null)

  if (heard?.connected) {
    return (
      <Stack gap="var(--s4)" align="flex-start">
        <div className="linkup-done">
          <IconCircleCheck size={28} stroke={1.6} />
          <div>
            <div className="linkup-done-title">{code.key} is linked up</div>
            <Text size="sm" c="dimmed">
              {[
                heard.hostname,
                plural(heard.folders.length, 'folder'),
                'shared',
              ]
                .filter(Boolean)
                .join(' · ')}
              . To search a folder, attach it as A folder reached through this
              machine.
            </Text>
          </div>
        </div>
        <Button radius="xl" color="brand" onClick={onClose}>
          Done
        </Button>
      </Stack>
    )
  }

  if (!info || !build) {
    return (
      <Alert color="yellow" title="This server holds no agent to hand out">
        The agent builds live in the folder XIXO_AGENT_DIR names. The server
        image puts them there.
      </Alert>
    )
  }

  const shown = steps({
    xixo: info.xixo,
    issuer: info.issuer,
    code: code.code,
    name: code.key,
    build,
    folders: typed,
    extractsForOthers,
    lend,
  })

  const minutes = Math.floor(left / 60)
  const seconds = `${left % 60}`.padStart(2, '0')

  return (
    <Stack gap="var(--s5)">
      <div className="linkup-code" data-spent={left === 0}>
        <span>
          {left > 0
            ? `The code in these commands works once, for the next ${minutes}:${seconds}.`
            : 'The code has run out. Get a fresh one and copy the commands again.'}
        </span>
        <Button
          size="compact-sm"
          radius="xl"
          variant={left > 0 ? 'default' : 'filled'}
          color={left > 0 ? undefined : 'brand'}
          loading={busy}
          onClick={onFresh}
        >
          Get a fresh code
        </Button>
      </div>

      <Stack gap="var(--s3)">
        <div className="label">The machine</div>
        <Select
          size="md"
          aria-label="The machine's system"
          allowDeselect={false}
          value={build.file}
          onChange={(next) => next && setFile(next)}
          data={builds.map((held) => ({
            value: held.file,
            label: buildLabel(held),
          }))}
        />
        <Text size="xs" c="dimmed">
          {build.os === 'darwin'
            ? 'Apple menu, About This Mac, says Apple M1 or later for Apple silicon. It needs curl, which macOS has.'
            : 'uname -m on the machine prints x86_64 for Intel or AMD, and aarch64 for ARM. It needs systemd, curl, and sudo.'}
        </Text>
        <Textarea
          size="md"
          label="Folders it shares"
          description="One absolute path per line. These fill in the commands. The config on the machine decides, and xixo reads nothing outside the folders it names."
          placeholder="/srv/media"
          autosize
          minRows={2}
          maxRows={8}
          spellCheck={false}
          value={folders}
          onChange={(event) => setFolders(event.currentTarget.value)}
          error={problems.length > 0 ? problems.join('. ') : undefined}
        />
        <details className="linkup-options">
          <summary>More options</summary>
          <Stack gap="var(--s3)" mt="var(--s3)">
            <Checkbox
              label="Help read files from other machines"
              description="xixo may send it files from elsewhere to read, when it has the programs for them."
              checked={extractsForOthers}
              onChange={(event) =>
                setExtractsForOthers(event.currentTarget.checked)
              }
            />
            <Checkbox
              label="Let xixo fetch whole files from it"
              description="For downloads, previews, and reading on another machine. Left off, only text and thumbnails leave it."
              checked={lend}
              onChange={(event) => setLend(event.currentTarget.checked)}
            />
          </Stack>
        </details>
      </Stack>

      <ol className="linkup-steps">
        {shown.map((step, index) => (
          <li key={step.title} className="linkup-step">
            <span className="linkup-step-n">{index + 1}</span>
            <div className="linkup-step-body">
              <div className="linkup-step-title">{step.title}</div>
              <Text size="sm" c="dimmed">
                {step.detail}
              </Text>
              <div className="linkup-command">
                <Code block>{step.command}</Code>
                <CopyButton value={step.command}>
                  {({ copied, copy }) => (
                    <Button
                      size="compact-sm"
                      radius="xl"
                      variant="default"
                      className="linkup-copy"
                      disabled={problems.length > 0}
                      onClick={copy}
                    >
                      {copied ? 'Copied' : 'Copy'}
                    </Button>
                  )}
                </CopyButton>
              </div>
            </div>
          </li>
        ))}
      </ol>

      <div className="linkup-wait" data-linked={Boolean(heard?.linked)}>
        <span className="linkup-dot" />
        {heard?.linked
          ? `${code.key} is linked. Waiting for its agent to start.`
          : `Waiting for ${code.key} to link up. Run the steps in one terminal on the machine.`}
      </div>
    </Stack>
  )
}
