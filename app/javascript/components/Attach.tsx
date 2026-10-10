import {
  Alert,
  Button,
  Checkbox,
  Group,
  Loader,
  Modal,
  SegmentedControl,
  Select,
  Stack,
  Text,
  Textarea,
  TextInput,
} from '@mantine/core'
import {
  IconAddressBook,
  IconArrowLeft,
  IconBrandGithub,
  IconBrandGoogleDrive,
  IconBrandNotion,
  IconBrandOnedrive,
  IconBrandSlack,
  IconBucket,
  IconCalendar,
  IconCloud,
  IconCpu,
  IconDatabase,
  IconFolders,
  IconGitBranch,
  IconMail,
  IconMapPin,
  IconNetwork,
  IconPlug,
  IconPuzzle,
  IconRss,
  IconSearch,
  IconServer2,
  IconWorld,
  IconWorldDownload,
} from '@tabler/icons-react'
import { type CSSProperties, useState } from 'react'
import {
  AttachResourceDocument,
  ResourceTypesDocument,
  type ResourceTypesQuery,
  UpdateResourceDocument,
} from 'xixo'
import { useMutation, useQuery } from 'xixo/react'

type Attaching = ResourceTypesQuery['resourceTypes'][number]

type Field = Attaching['fields'][number]

type Typed = Record<string, string | boolean>

export interface Editing {
  id: string
  type: string
  key: string
  name?: string | null
  settings: Record<string, unknown>
  heldCredentials: string[]
  via?: string | null
}

const DIRECT = ' directly'

type Glyph = typeof IconPuzzle

const GLYPHS: Record<string, Glyph> = {
  database: IconDatabase,
  s3: IconBucket,
  webdav: IconServer2,
  filesystem: IconFolders,
  'oauth-google': IconBrandGoogleDrive,
  'microsoft-graph': IconBrandOnedrive,
  search: IconSearch,
  weather: IconCloud,
  places: IconMapPin,
  curl: IconWorldDownload,
  web: IconWorld,
  rss: IconRss,
  imap: IconMail,
  caldav: IconCalendar,
  carddav: IconAddressBook,
  'openai-compatible': IconCpu,
  mcp: IconPlug,
  github: IconBrandGithub,
  notion: IconBrandNotion,
  slack: IconBrandSlack,
  git: IconGitBranch,
  tailnet: IconNetwork,
}

const GROUPS: {
  title: string
  short: string
  tone: string
  types: string[]
}[] = [
  {
    title: 'Where your files live',
    short: 'Files',
    tone: 'var(--k-text)',
    types: ['s3', 'webdav', 'filesystem', 'oauth-google', 'microsoft-graph'],
  },
  {
    title: 'The web',
    short: 'Web',
    tone: 'var(--k-data)',
    types: ['search', 'curl', 'web', 'rss', 'weather', 'places'],
  },
  {
    title: 'Mail, calendars and contacts',
    short: 'Mail',
    tone: 'var(--k-email)',
    types: ['imap', 'caldav', 'carddav'],
  },
  {
    title: 'Models and tools',
    short: 'Models',
    tone: 'var(--k-image)',
    types: ['openai-compatible', 'mcp'],
  },
  {
    title: 'Where you work',
    short: 'Work',
    tone: 'var(--k-page)',
    types: ['github', 'notion', 'slack', 'git'],
  },
]

export function glyphFor(type: string): Glyph {
  return GLYPHS[type] ?? IconPuzzle
}

function gist(blurb: string) {
  const first = blurb.split(/(?<=\.)\s/)[0] ?? blurb

  return first.length > 110 ? `${first.slice(0, 107)}…` : first
}

function grouped(types: readonly Attaching[]) {
  const placed = new Set(GROUPS.flatMap((group) => group.types))
  const sections = GROUPS.map((group) => ({
    title: group.title,
    short: group.short,
    tone: group.tone,
    types: group.types.flatMap((name) =>
      types.filter((held) => held.type === name),
    ),
  }))
  const rest = types.filter((held) => !placed.has(held.type))

  return [
    ...sections,
    {
      title: 'Everything else',
      short: 'Other',
      tone: 'var(--k-file)',
      types: rest,
    },
  ].filter((section) => section.types.length > 0)
}

function asked(field: Field, typed: Typed) {
  return (field.shownWhen ?? []).every((condition) =>
    condition.values.includes(`${typed[condition.field] ?? ''}`),
  )
}

function seeded(type: Attaching, editing?: Editing): Typed {
  return Object.fromEntries(
    type.fields.map((field) => {
      const held = editing?.settings[field.name]

      if (editing?.heldCredentials.includes(field.name)) return [field.name, '']
      if (Array.isArray(held)) return [field.name, held.join('\n')]
      if (held !== undefined && held !== null)
        return [field.name, typeof held === 'boolean' ? held : `${held}`]

      return [
        field.name,
        field.kind === 'boolean' ? field.value === 'true' : (field.value ?? ''),
      ]
    }),
  )
}

export function Attach({
  opened,
  onClose,
  onAttached,
  editing,
  transports = [],
}: {
  opened: boolean
  onClose: () => void
  onAttached: () => void
  editing?: Editing
  transports?: string[]
}) {
  const { data, loading } = useQuery(ResourceTypesDocument, {})
  const attach = useMutation(AttachResourceDocument)
  const update = useMutation(UpdateResourceDocument)

  const [chosen, setChosen] = useState<string | null>(editing?.type ?? null)
  const [key, setKey] = useState(editing?.key ?? '')
  const [name, setName] = useState(editing?.name ?? '')
  const [typed, setTyped] = useState<Typed>({})
  const [seededFor, setSeededFor] = useState<string | null>(null)
  const [refused, setRefused] = useState<string | null>(null)
  const [warned, setWarned] = useState<string | null>(null)
  const [personal, setPersonal] = useState(false)
  const [via, setVia] = useState(editing?.via ?? DIRECT)

  const types = data?.resourceTypes ?? []
  const type = types.find((held) => held.type === chosen) ?? null
  const [find, setFind] = useState('')
  const [shelf, setShelf] = useState<string | null>(null)
  const needle = find.trim().toLowerCase()
  const everything = grouped(types)
  const sections = grouped(
    needle
      ? types.filter((held) =>
          `${held.label} ${held.type} ${held.blurb}`
            .toLowerCase()
            .includes(needle),
        )
      : types,
  ).filter((section) => shelf === null || section.short === shelf)

  if (editing && type && seededFor !== editing.id) {
    setTyped(seeded(type, editing))
    setSeededFor(editing.id)
  }

  const kept = (field: Field) =>
    editing?.heldCredentials.includes(field.name) ?? false

  const pick = (next: Attaching) => {
    setChosen(next.type)
    setKey((held) => held || next.type)
    setTyped(seeded(next))
    setPersonal(next.delegated)
    setRefused(null)
    setWarned(null)
  }

  const attaching = attach.loading || update.loading
  const shown = (type?.fields ?? []).filter((field) => asked(field, typed))
  const missing = shown.filter(
    (field) =>
      field.required && !kept(field) && !`${typed[field.name] ?? ''}`.trim(),
  )
  const ready = key.trim().length > 0 && missing.length === 0
  const routed = Boolean(type?.routable) && transports.length > 0

  async function save() {
    if (!type || !editing) return

    setRefused(null)
    setWarned(null)

    const { data: answered, error } = await update.attempt({
      id: editing.id,
      name: name.trim() || null,
      settings: Object.fromEntries(
        shown.map((field) => [field.name, typed[field.name]]),
      ),
      via: routed ? (via === DIRECT ? '' : via) : null,
    })

    if (!answered?.updateResource?.resource) {
      setRefused(error?.message ?? 'That could not be saved.')
      return
    }

    onAttached()

    if (answered.updateResource.checkError) {
      setWarned(answered.updateResource.checkError)
      return
    }

    onClose()
  }

  async function connect() {
    if (!type) return

    setRefused(null)
    setWarned(null)

    const { data: answered, error } = await attach.attempt({
      type: type.type,
      key: key.trim(),
      name: name.trim() || null,
      personal,
      settings: Object.fromEntries(
        shown.map((field) => [field.name, typed[field.name]]),
      ),
      via: routed && via !== DIRECT ? via : null,
    })

    if (!answered?.attachResource?.resource) {
      setRefused(error?.message ?? 'That could not be attached.')
      return
    }

    if (answered.attachResource.connectUrl) {
      window.location.assign(answered.attachResource.connectUrl)
      return
    }

    onAttached()

    if (answered.attachResource.checkError) {
      setWarned(answered.attachResource.checkError)
      return
    }

    onClose()
  }

  const Glyph = type ? glyphFor(type.type) : IconPuzzle

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={
        editing ? (
          `Change ${editing.key}`
        ) : type ? (
          <Button
            variant="subtle"
            color="gray"
            size="compact-sm"
            leftSection={<IconArrowLeft size={15} />}
            onClick={() => setChosen(null)}
            disabled={attaching}
          >
            All resources
          </Button>
        ) : (
          'Attach a resource'
        )
      }
      withCloseButton
      size={type ? 'lg' : 'xl'}
      padding="var(--s5)"
    >
      {loading && !data ? (
        <Loader size="sm" color="var(--accent)" />
      ) : !type ? (
        <div className="attach-picker">
          <div className="attach-intro">
            <TextInput
              size="md"
              radius="xl"
              autoFocus
              leftSection={<IconSearch size={16} stroke={1.8} />}
              placeholder="Find a kind of resource"
              aria-label="Find a kind of resource"
              value={find}
              onChange={(event) => setFind(event.currentTarget.value)}
            />

            <div className="shelf attach-shelves">
              <button
                type="button"
                className="chip"
                data-on={shelf === null}
                aria-pressed={shelf === null}
                onClick={() => setShelf(null)}
              >
                All
              </button>
              {everything.map((section) => (
                <button
                  key={section.short}
                  type="button"
                  className="chip"
                  data-on={shelf === section.short}
                  aria-pressed={shelf === section.short}
                  style={{ '--tone': section.tone } as CSSProperties}
                  onClick={() =>
                    setShelf(shelf === section.short ? null : section.short)
                  }
                >
                  <span className="attach-dot" />
                  {section.short}
                </button>
              ))}
            </div>
          </div>

          {sections.map((section) => (
            <section
              key={section.title}
              className="attach-group"
              style={{ '--tone': section.tone } as CSSProperties}
            >
              <h3 className="attach-group-title">{section.title}</h3>
              <div className="attach-grid">
                {section.types.map((held) => {
                  const Icon = glyphFor(held.type)
                  const meta = held.delegated
                    ? 'Account'
                    : held.fields.length === 0
                      ? 'Instant'
                      : held.syncs
                        ? 'Syncs'
                        : null

                  return (
                    <button
                      key={held.type}
                      type="button"
                      className="attach-card"
                      title={held.blurb}
                      onClick={() => pick(held)}
                    >
                      <span className="attach-card-top">
                        <span className="attach-icon">
                          <Icon size={20} stroke={1.7} />
                        </span>
                        {meta && <span className="attach-meta">{meta}</span>}
                      </span>
                      <span className="attach-name">{held.label}</span>
                      <span className="attach-gist">{gist(held.blurb)}</span>
                    </button>
                  )
                })}
              </div>
            </section>
          ))}

          {sections.length === 0 && (
            <div className="attach-none">
              Nothing matches {find.trim() || 'that'}.
            </div>
          )}
        </div>
      ) : (
        <Stack gap="var(--s5)">
          <div className="attach-head">
            <span className="attach-icon attach-icon-large">
              <Glyph size={28} stroke={1.5} />
            </span>
            <div style={{ minWidth: 0 }}>
              <h2 className="attach-title">{type.label}</h2>
              <Text size="sm" c="dimmed" mt="var(--s1)">
                {type.blurb}
              </Text>
            </div>
          </div>

          <Stack gap="var(--s3)">
            <div className="label">Name it</div>
            <TextInput
              size="md"
              label={type.names}
              description="Unique among resources of this type. It cannot be changed later."
              autoFocus={!editing}
              withAsterisk
              disabled={Boolean(editing)}
              value={key}
              onChange={(event) => setKey(event.currentTarget.value)}
            />

            <TextInput
              size="md"
              label="Called"
              description="What it is called in listings. Left off, the name above stands in."
              value={name}
              onChange={(event) => setName(event.currentTarget.value)}
            />

            {!editing && (
              <Stack gap="var(--s1)">
                <Text size="sm" fw={500}>
                  Who can use it
                </Text>
                <SegmentedControl
                  value={personal ? 'me' : 'everyone'}
                  onChange={(next) => setPersonal(next === 'me')}
                  data={[
                    { value: 'everyone', label: 'Everyone here' },
                    { value: 'me', label: 'Only me' },
                  ]}
                />
                <Text size="xs" c="dimmed">
                  {personal
                    ? 'Nobody else sees it, or reaches it through a tool, and agents use it only in runs you start. What it syncs, and what those agents write, is still catalogued for everyone.'
                    : 'Anyone signed in here can use it, and so can the agents working on feeds.'}
                </Text>
              </Stack>
            )}
          </Stack>

          {type.fields.length > 0 && (
            <Stack gap="var(--s3)">
              <div className="label">
                {type.delegated ? 'Before you connect' : 'Connection'}
              </div>
              {shown.map((field) => (
                <Asked
                  key={field.name}
                  field={field}
                  kept={kept(field)}
                  value={typed[field.name]}
                  onChange={(next) =>
                    setTyped((held) => ({ ...held, [field.name]: next }))
                  }
                />
              ))}
              {routed && (
                <Select
                  size="md"
                  label="Reached through"
                  description="A network xixo dials it over. Through one, only addresses on that network are reached."
                  allowDeselect={false}
                  value={via}
                  onChange={(next) => setVia(next ?? DIRECT)}
                  data={[
                    { value: DIRECT, label: 'Directly' },
                    ...transports.map((held) => ({ value: held, label: held })),
                  ]}
                />
              )}
            </Stack>
          )}

          {refused && <Alert color="red">{refused}</Alert>}

          {warned && (
            <Alert
              color="yellow"
              title={
                editing
                  ? 'Saved, but it did not answer'
                  : 'Attached, but it did not answer'
              }
            >
              {warned}
            </Alert>
          )}

          <Group justify="flex-end" gap="var(--s3)" className="attach-actions">
            <Button size="md" radius="xl" variant="default" onClick={onClose}>
              {warned ? 'Done' : 'Cancel'}
            </Button>
            <Button
              size="md"
              radius="xl"
              color="brand"
              onClick={editing ? save : connect}
              loading={attaching}
              disabled={editing ? missing.length > 0 : !ready}
            >
              {editing
                ? 'Save it'
                : type.delegated || typed.auth === 'masks'
                  ? 'Attach and connect'
                  : 'Attach it'}
            </Button>
          </Group>
        </Stack>
      )}
    </Modal>
  )
}

function Asked({
  field,
  kept,
  value,
  onChange,
}: {
  field: Field
  kept: boolean
  value: string | boolean | undefined
  onChange: (next: string | boolean) => void
}) {
  if (field.kind === 'choice') {
    return (
      <Select
        size="md"
        label={field.label}
        description={field.help}
        allowDeselect={false}
        withAsterisk={field.required}
        value={typeof value === 'string' ? value : null}
        onChange={(next) => next !== null && onChange(next)}
        data={(field.options ?? []).map((option) => ({
          value: option.value,
          label: option.label,
        }))}
      />
    )
  }

  if (field.kind === 'list') {
    return (
      <Textarea
        size="md"
        label={field.label}
        description={field.help}
        placeholder={field.placeholder ?? undefined}
        withAsterisk={field.required}
        autosize
        minRows={3}
        maxRows={12}
        spellCheck={false}
        autoComplete="off"
        value={typeof value === 'string' ? value : ''}
        onChange={(event) => onChange(event.currentTarget.value)}
      />
    )
  }

  if (field.kind === 'boolean') {
    return (
      <Checkbox
        size="md"
        label={field.label}
        description={field.help}
        checked={value === true}
        onChange={(event) => onChange(event.currentTarget.checked)}
      />
    )
  }

  return (
    <TextInput
      size="md"
      label={field.label}
      description={
        kept
          ? [field.help, 'Something is held. Left empty, it stays as it is.']
              .filter(Boolean)
              .join(' ')
          : field.help
      }
      placeholder={
        kept
          ? field.secret
            ? '••••••••'
            : 'as it is'
          : (field.placeholder ?? undefined)
      }
      type={field.secret ? 'password' : 'text'}
      autoComplete={field.secret ? 'new-password' : 'off'}
      inputMode={field.kind === 'integer' ? 'numeric' : undefined}
      withAsterisk={field.required && !kept}
      value={typeof value === 'string' ? value : ''}
      onChange={(event) => onChange(event.currentTarget.value)}
    />
  )
}
