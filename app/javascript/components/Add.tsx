import {
  Alert,
  Button,
  Group,
  Modal,
  Stack,
  Text,
  Textarea,
} from '@mantine/core'
import { IconArrowBarToDown, IconFolder } from '@tabler/icons-react'
import {
  AddNoteDocument,
  FetchUrlDocument,
  SnapshotUrlDocument,
} from '@xixo/client'
import { useMutation } from '@xixo/client/react'
import {
  type ChangeEvent,
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { Link } from 'react-router-dom'
import { asUrl, type Intent, intentFor, shortly } from '../add'
import { useUploads } from './Uploads'

export interface Added {
  key: string
  label: string
  detail: string
  to: string
}

export type Outcome =
  | { ok: true; added: Added }
  | { ok: false; refused: string }

interface Adding {
  opened: boolean
  added: Added[]
  addedAt: number | null
  busy: boolean
  open: (seed?: string) => void
  close: () => void
  keepUrl: (url: string, intent: Intent) => Promise<Outcome>
  keepNote: (title: string, body: string) => Promise<Outcome>
}

const Context = createContext<Adding | null>(null)

export function useAdd() {
  const held = useContext(Context)

  if (!held) throw new Error('useAdd needs an AddProvider above it')

  return held
}

function typing(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false

  return (
    target.isContentEditable ||
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement
  )
}

export function AddProvider({ children }: { children: ReactNode }) {
  const uploads = useUploads()

  const [opened, setOpened] = useState(false)
  const [text, setText] = useState('')
  const [refused, setRefused] = useState<string | null>(null)
  const [added, setAdded] = useState<Added[]>([])
  const [addedAt, setAddedAt] = useState<number | null>(null)

  const note = useMutation(AddNoteDocument)
  const snapshot = useMutation(SnapshotUrlDocument)
  const fetched = useMutation(FetchUrlDocument)

  const busy = note.loading || snapshot.loading || fetched.loading

  const remember = useCallback((entry: Added) => {
    setAdded((held) => [entry, ...held].slice(0, 6))
    setAddedAt(Date.now())
  }, [])

  const keepUrl = useCallback(
    async (given: string, wanted: Intent): Promise<Outcome> => {
      const parsed = asUrl(given)

      if (!parsed) return { ok: false, refused: 'That is not a web address.' }

      const address = parsed.toString()
      const where = shortly(parsed)

      if (wanted === 'snapshot') {
        const { data: answered, error } = await snapshot.attempt({
          url: address,
        })
        const run = answered?.snapshotUrl?.run

        if (!run)
          return {
            ok: false,
            refused: error?.message ?? 'That page could not be taken.',
          }

        const entry = {
          key: run.id,
          label: where,
          detail: 'being rendered',
          to: '/',
        }

        remember(entry)

        return { ok: true, added: entry }
      }

      const { data: answered, error } = await fetched.attempt({
        url: address,
      })
      const run = answered?.fetchUrl?.run

      if (!run)
        return {
          ok: false,
          refused: error?.message ?? 'That file could not be fetched.',
        }

      const entry = {
        key: run.id,
        label: where,
        detail: 'being fetched',
        to: '/',
      }

      remember(entry)

      return { ok: true, added: entry }
    },
    [snapshot, fetched, remember],
  )

  const keepNote = useCallback(
    async (given: string, written: string): Promise<Outcome> => {
      if (!written.trim())
        return { ok: false, refused: 'A note needs something in it.' }

      const { data: answered, error } = await note.attempt({
        title: given.trim() || null,
        body: written,
      })
      const item = answered?.addNote?.feed

      if (!item)
        return {
          ok: false,
          refused: error?.message ?? 'That note could not be kept.',
        }

      const entry = {
        key: item.id,
        label: item.title ?? 'Note',
        detail: 'kept',
        to: `/items/${item.id}`,
      }

      remember(entry)

      return { ok: true, added: entry }
    },
    [note, remember],
  )

  const open = useCallback((seed?: string) => {
    setRefused(null)
    if (seed !== undefined) setText(seed)
    setOpened(true)
  }, [])

  // Whatever is on the clipboard decides what it becomes: files go the way a
  // drop goes, and anything with text in it opens the box already filled.
  useEffect(() => {
    const pasted = (event: ClipboardEvent) => {
      if (typing(event.target)) return

      const data = event.clipboardData

      if (!data) return

      if (data.files.length > 0) {
        event.preventDefault()
        uploads.add(data.files)
        return
      }

      const written = data.getData('text/plain')

      if (!written.trim()) return

      event.preventDefault()
      open(written)
    }

    window.addEventListener('paste', pasted)

    return () => window.removeEventListener('paste', pasted)
  }, [uploads.add, open])

  const value = useMemo<Adding>(
    () => ({
      opened,
      added,
      addedAt,
      busy,
      open,
      close: () => setOpened(false),
      keepUrl,
      keepNote,
    }),
    [opened, added, addedAt, busy, open, keepUrl, keepNote],
  )

  const found = asUrl(text)

  async function keep() {
    setRefused(null)

    const outcome = found
      ? await keepUrl(text, intentFor(found))
      : await keepNote('', text)

    if (!outcome.ok) {
      setRefused(outcome.refused)
      return
    }

    setText('')
  }

  return (
    <Context.Provider value={value}>
      {children}

      <Modal
        opened={opened}
        onClose={() => setOpened(false)}
        title="Keep something"
        size="lg"
      >
        <Stack gap="var(--s4)">
          <Textarea
            autoFocus
            autosize
            minRows={3}
            maxRows={14}
            value={text}
            disabled={busy}
            aria-label="A link, or a note"
            placeholder="Paste a link, or write a note."
            onChange={(event) => {
              setText(event.currentTarget.value)
              setRefused(null)
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
                event.preventDefault()
                if (text.trim() && !busy) keep()
              }
            }}
          />

          <Group justify="space-between" gap="var(--s3)">
            <Reads text={text} found={found} />

            <Button
              onClick={keep}
              loading={busy}
              disabled={!text.trim()}
              color="brand"
              radius="xl"
            >
              Keep it
            </Button>
          </Group>

          <Files />

          {refused && <Alert color="red">{refused}</Alert>}

          {added.length > 0 && (
            <div className="added">
              {added.map((entry) => (
                <Link
                  key={entry.key}
                  to={entry.to}
                  className="added-row"
                  onClick={() => setOpened(false)}
                >
                  <span className="added-what">{entry.label}</span>
                  <span className="added-where">{entry.detail}</span>
                </Link>
              ))}
            </div>
          )}
        </Stack>
      </Modal>
    </Context.Provider>
  )
}

// The box says what it made of what you typed, so nothing has to be chosen.
function Reads({ text, found }: { text: string; found: URL | null }) {
  if (!text.trim()) {
    return (
      <Text size="xs" c="dimmed">
        A web address is kept as a page. Anything else is a note.
      </Text>
    )
  }

  if (!found) {
    return (
      <Text size="xs" c="dimmed">
        Kept as a note. Its first line names it.
      </Text>
    )
  }

  return (
    <Text size="xs" c="dimmed">
      <span className="mono" style={{ color: 'var(--accent)' }}>
        {shortly(found)}
      </span>{' '}
      {intentFor(found) === 'fetch'
        ? '— the file at that address'
        : '— the page as it looks now'}
    </Text>
  )
}

function Files() {
  const { add } = useUploads()
  const loose = useRef<HTMLInputElement>(null)
  const folder = useRef<HTMLInputElement>(null)

  const chosen = (event: ChangeEvent<HTMLInputElement>) => {
    if (event.currentTarget.files?.length) add(event.currentTarget.files)
    event.currentTarget.value = ''
  }

  return (
    <div className="drop-well">
      <Text size="sm" c="dimmed" maw="46ch">
        Files go straight to your default storage. Drop them anywhere on the
        window, paste them, or choose them here.
      </Text>

      <Group gap="var(--s2)" wrap="nowrap">
        <Button
          size="xs"
          radius="xl"
          variant="default"
          leftSection={<IconArrowBarToDown size={15} stroke={1.6} />}
          onClick={() => loose.current?.click()}
        >
          Files
        </Button>
        <Button
          size="xs"
          radius="xl"
          variant="default"
          leftSection={<IconFolder size={15} stroke={1.6} />}
          onClick={() => folder.current?.click()}
        >
          A folder
        </Button>
      </Group>

      <input ref={loose} type="file" multiple hidden onChange={chosen} />
      <input
        ref={folder}
        type="file"
        multiple
        hidden
        onChange={chosen}
        {...({ webkitdirectory: '' } as Record<string, string>)}
      />
    </div>
  )
}
