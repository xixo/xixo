import { ActionIcon, Button, Group, Text } from '@mantine/core'
import { IconArrowBarToDown, IconX } from '@tabler/icons-react'
import { metaCSRFToken } from '@uris-to/client'
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { session } from '../hooks/useSession'
import {
  type Dropped,
  entriesFrom,
  type Failure,
  filesFrom,
  looseFiles,
  type Twin,
  Unauthorized,
  upload,
} from '../uploads'
import { Spectrum } from './Spectrum'

interface Tally {
  found: number
  done: number
  skipped: number
  twins: Twin[]
  failures: Failure[]
  current: string | null
  walking: boolean
  running: boolean
  waiting: number
  settledAt: number | null
}

const EMPTY: Tally = {
  found: 0,
  done: 0,
  skipped: 0,
  twins: [],
  failures: [],
  current: null,
  walking: false,
  running: false,
  waiting: 0,
  settledAt: null,
}

type Sources = { entries?: FileSystemEntry[]; files?: Dropped[] }

interface Uploads extends Tally {
  dragging: boolean
  add: (list: FileList) => void
  cancel: () => void
  dismiss: () => void
}

const Context = createContext<Uploads | null>(null)

export function useUploads() {
  const held = useContext(Context)

  if (!held) throw new Error('useUploads needs an UploadsProvider above it')

  return held
}

const counted = (value: number) => value.toLocaleString()

export function UploadsProvider({ children }: { children: ReactNode }) {
  const [tally, setTally] = useState<Tally>(EMPTY)
  const [dragging, setDragging] = useState(false)
  const [pending, setPending] = useState(0)

  const live = useRef<Tally>(EMPTY)
  const control = useRef<AbortController | null>(null)
  const queued = useRef<Sources[]>([])
  const runner = useRef<(sources: Sources) => void>(() => {})
  const depth = useRef(0)

  const publish = useCallback(() => setTally({ ...live.current }), [])

  const start = useCallback(
    (sources: Sources) => {
      const controller = new AbortController()
      control.current = controller

      live.current = {
        ...EMPTY,
        walking: true,
        running: true,
        waiting: queued.current.length,
      }
      publish()

      const handlers = {
        onFound: (count: number) => {
          live.current.found = count
        },
        onWalked: () => {
          live.current.walking = false
        },
        onSent: (path: string) => {
          live.current.done += 1
          live.current.current = path
        },
        onTwin: (twin: Twin) => {
          live.current.skipped += 1
          live.current.current = twin.path
          live.current.twins = [...live.current.twins, twin].slice(-50)
        },
        onFailed: (failure: Failure) => {
          live.current.failures = [...live.current.failures, failure].slice(-50)
        },
      }

      upload(sources, handlers, metaCSRFToken(), controller.signal)
        .catch((error: unknown) => {
          if (error instanceof Unauthorized) {
            session.login()
            return
          }

          live.current.failures = [
            ...live.current.failures,
            {
              path: '',
              reason: error instanceof Error ? error.message : 'upload failed',
            },
          ]
        })
        .finally(() => {
          const next = queued.current.shift()

          if (next && !controller.signal.aborted) {
            runner.current(next)
            return
          }

          live.current.running = false
          live.current.walking = false
          live.current.waiting = 0
          live.current.settledAt = Date.now()
          publish()
        })
    },
    [publish],
  )

  runner.current = start

  const begin = useCallback(
    (sources: Sources) => {
      if (live.current.running) {
        queued.current.push(sources)
        live.current.waiting = queued.current.length
        publish()
        return
      }

      start(sources)
    },
    [start, publish],
  )

  useEffect(() => {
    if (!tally.running) return

    const timer = window.setInterval(publish, 140)

    return () => window.clearInterval(timer)
  }, [tally.running, publish])

  useEffect(() => {
    const carriesFiles = (event: DragEvent) =>
      Array.from(event.dataTransfer?.types ?? []).includes('Files')

    const enter = (event: DragEvent) => {
      if (!carriesFiles(event)) return

      depth.current += 1
      setDragging(true)
      setPending(event.dataTransfer?.items.length ?? 0)
    }

    const leave = (event: DragEvent) => {
      if (!carriesFiles(event)) return

      depth.current = Math.max(0, depth.current - 1)
      if (depth.current === 0) setDragging(false)
    }

    const over = (event: DragEvent) => {
      if (!carriesFiles(event)) return

      event.preventDefault()

      if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    }

    const drop = (event: DragEvent) => {
      if (!event.dataTransfer || !carriesFiles(event)) return

      event.preventDefault()
      depth.current = 0
      setDragging(false)

      const entries = entriesFrom(event.dataTransfer)
      const files = entries.length > 0 ? null : looseFiles(event.dataTransfer)

      if (entries.length === 0 && files?.length === 0) return

      begin(entries.length > 0 ? { entries } : { files: files ?? [] })
    }

    const cancelled = () => {
      depth.current = 0
      setDragging(false)
    }

    window.addEventListener('dragenter', enter)
    window.addEventListener('dragleave', leave)
    window.addEventListener('dragover', over)
    window.addEventListener('drop', drop)
    window.addEventListener('dragend', cancelled)

    return () => {
      window.removeEventListener('dragenter', enter)
      window.removeEventListener('dragleave', leave)
      window.removeEventListener('dragover', over)
      window.removeEventListener('drop', drop)
      window.removeEventListener('dragend', cancelled)
    }
  }, [begin])

  const add = useCallback(
    (list: FileList) => begin({ files: filesFrom(list) }),
    [begin],
  )

  const cancel = useCallback(() => {
    queued.current = []
    control.current?.abort()
    live.current.running = false
    live.current.walking = false
    live.current.waiting = 0
    live.current.settledAt = Date.now()
    publish()
  }, [publish])

  const dismiss = useCallback(() => {
    live.current = EMPTY
    publish()
  }, [publish])

  const value = useMemo<Uploads>(
    () => ({ ...tally, dragging, add, cancel, dismiss }),
    [tally, dragging, add, cancel, dismiss],
  )

  return (
    <Context.Provider value={value}>
      {children}
      {dragging && <DropField pending={pending} />}
      <Tray />
    </Context.Provider>
  )
}

function DropField({ pending }: { pending: number }) {
  return (
    <div className="drop">
      <div className="drop-inner">
        <div className="drop-word">Add to the catalog</div>
        <div style={{ marginTop: 'var(--s5)' }}>
          <Spectrum />
        </div>
        <div className="drop-note">
          {pending > 0
            ? `${counted(pending)} ${pending === 1 ? 'item' : 'items'}, folders and all. Everything inside gets written to your default storage, then indexed.`
            : 'Whatever you drop gets written to your default storage, then indexed.'}
        </div>
      </div>
    </div>
  )
}

function Tray() {
  const {
    found,
    done,
    skipped,
    twins,
    failures,
    current,
    walking,
    running,
    waiting,
    settledAt,
    cancel,
    dismiss,
  } = useUploads()

  if (!running && settledAt === null) return null

  const handled = done + skipped
  const share =
    found > 0 ? Math.min(100, Math.round((handled / found) * 100)) : 0

  return (
    <aside className="tray" aria-live="polite">
      <div className="tray-head">
        <IconArrowBarToDown size={17} stroke={1.6} color="var(--brass)" />
        <Text fw={600} size="sm" style={{ color: 'var(--bright)' }}>
          {running
            ? walking
              ? `Reading — ${counted(found)} found`
              : `Adding ${counted(handled)} of ${counted(found)}`
            : skipped > 0
              ? `Added ${counted(done)} · ${counted(skipped)} already here`
              : `Added ${counted(done)}`}
        </Text>
        <Group gap="var(--s1)" ml="auto" wrap="nowrap">
          {running ? (
            <Button
              size="compact-xs"
              variant="subtle"
              color="gray"
              onClick={cancel}
            >
              Stop
            </Button>
          ) : (
            <ActionIcon
              variant="subtle"
              color="gray"
              size="sm"
              onClick={dismiss}
            >
              <IconX size={15} />
            </ActionIcon>
          )}
        </Group>
      </div>

      <div className="tray-bar" data-walking={walking}>
        <span style={{ width: walking ? '100%' : `${share}%` }} />
      </div>

      <div className="tray-body">
        {waiting > 0 && (
          <div style={{ marginTop: 'var(--s3)' }}>
            {counted(waiting)} more {waiting === 1 ? 'drop' : 'drops'} waiting
            their turn
          </div>
        )}

        {current && running && (
          <div className="tray-path" style={{ marginTop: 'var(--s3)' }}>
            {current}
          </div>
        )}

        {!running && failures.length === 0 && (
          <div style={{ marginTop: 'var(--s3)' }}>
            {skipped > 0 ? 'Nothing else was needed.' : 'Everything landed.'}
          </div>
        )}

        {skipped > 0 && (
          <div className="tray-fails">
            <div style={{ marginBottom: 'var(--s2)' }}>
              {counted(skipped)} already here, so not added again
            </div>
            {twins.slice(-8).map((twin, at) => (
              <div
                className="tray-twin"
                // biome-ignore lint/suspicious/noArrayIndexKey: two drops can match the same file
                key={`${at}-${twin.path}`}
              >
                {twin.path}
                {twin.twin ? ` — same as ${twin.twin}` : ''}
              </div>
            ))}
          </div>
        )}

        {failures.length > 0 && (
          <div className="tray-fails">
            <div style={{ marginBottom: 'var(--s2)' }}>
              {counted(failures.length)} did not land
            </div>
            {failures.slice(-8).map((failure, at) => (
              <div
                className="tray-fail"
                // biome-ignore lint/suspicious/noArrayIndexKey: two files can fail the same way
                key={`${at}-${failure.path}`}
              >
                {failure.path || 'batch'} — {failure.reason}
              </div>
            ))}
          </div>
        )}
      </div>
    </aside>
  )
}
