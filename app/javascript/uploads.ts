export const WORKERS = 6
const BUFFER = 512
const ATTEMPTS = 3

export class Unauthorized extends Error {}

export class Refused extends Error {}

export interface Dropped {
  path: string
  open: () => Promise<File>
}

export interface Twin {
  path: string
  twin: string | null
}

export interface Failure {
  path: string
  reason: string
}

export interface Handlers {
  onFound: (count: number) => void
  onWalked: () => void
  onSent: (path: string) => void
  onTwin: (twin: Twin) => void
  onFailed: (failure: Failure) => void
}

class Channel<T> {
  private items: T[] = []
  private takers: ((value: T | null) => void)[] = []
  private room: (() => void)[] = []
  private closed = false

  constructor(private readonly limit: number) {}

  get shut() {
    return this.closed
  }

  async put(item: T) {
    if (this.closed) return

    const taker = this.takers.shift()

    if (taker) {
      taker(item)
      return
    }

    this.items.push(item)

    if (this.items.length >= this.limit) {
      await new Promise<void>((resolve) => this.room.push(resolve))
    }
  }

  close() {
    this.closed = true

    for (const taker of this.takers.splice(0)) taker(null)
    for (const waiting of this.room.splice(0)) waiting()
  }

  async take(): Promise<T | null> {
    const item = this.items.shift()

    if (item !== undefined) {
      if (this.items.length < this.limit) {
        for (const waiting of this.room.splice(0)) waiting()
      }

      return item
    }

    if (this.closed) return null

    return new Promise<T | null>((resolve) => this.takers.push(resolve))
  }
}

function readBatch(reader: FileSystemDirectoryReader) {
  return new Promise<FileSystemEntry[]>((resolve, reject) =>
    reader.readEntries(resolve, reject),
  )
}

async function children(directory: FileSystemDirectoryEntry) {
  const reader = directory.createReader()
  const all: FileSystemEntry[] = []

  for (;;) {
    const batch = await readBatch(reader)

    if (batch.length === 0) return all

    all.push(...batch)
  }
}

function openFile(entry: FileSystemFileEntry) {
  return new Promise<File>((resolve, reject) => entry.file(resolve, reject))
}

export function entriesFrom(transfer: DataTransfer): FileSystemEntry[] {
  return Array.from(transfer.items).flatMap((item) => {
    const entry = item.kind === 'file' ? item.webkitGetAsEntry() : null

    return entry ? [entry] : []
  })
}

export function looseFiles(transfer: DataTransfer): Dropped[] {
  return Array.from(transfer.files).map((file) => ({
    path: file.webkitRelativePath || file.name,
    open: async () => file,
  }))
}

export function filesFrom(list: FileList): Dropped[] {
  return Array.from(list).map((file) => ({
    path: file.webkitRelativePath || file.name,
    open: async () => file,
  }))
}

async function walk(
  roots: FileSystemEntry[],
  channel: Channel<Dropped>,
  onFound: (count: number) => void,
  signal: AbortSignal,
) {
  const stack = [...roots].reverse()
  let found = 0

  while (stack.length > 0 && !signal.aborted && !channel.shut) {
    const entry = stack.pop()

    if (!entry) break

    if (entry.isFile) {
      const file = entry as FileSystemFileEntry

      found += 1
      onFound(found)

      await channel.put({
        path: entry.fullPath.replace(/^\/+/, ''),
        open: () => openFile(file),
      })
    } else if (entry.isDirectory) {
      const kids = await children(entry as FileSystemDirectoryEntry)

      for (let index = kids.length - 1; index >= 0; index -= 1) {
        stack.push(kids[index])
      }
    }
  }
}

async function send(
  item: Dropped,
  csrf: string | null,
  signal: AbortSignal,
): Promise<Twin | null> {
  const file = await item.open()
  const form = new FormData()

  form.append('file', file, file.name)
  form.append('path', item.path)

  const response = await fetch('/uploads', {
    method: 'POST',
    body: form,
    signal,
    credentials: 'same-origin',
    headers: { 'X-CSRF-Token': csrf ?? '' },
  })

  if (response.status === 401)
    throw new Unauthorized('sign in again to add items')
  if (response.ok) {
    if (response.status !== 200) return null

    const held = await response.json().catch(() => null)

    return held?.duplicate ? { path: item.path, twin: held.twin ?? null } : null
  }

  const body = await response.json().catch(() => null)
  const reason = body?.error ?? `the server said ${response.status}`
  const permanent =
    response.status >= 400 && response.status < 500 && response.status !== 429

  throw permanent ? new Refused(reason) : new Error(reason)
}

async function drain(
  channel: Channel<Dropped>,
  handlers: Handlers,
  csrf: string | null,
  signal: AbortSignal,
) {
  for (;;) {
    const item = await channel.take()

    if (item === null || signal.aborted) return

    let attempt = 0

    for (;;) {
      attempt += 1

      try {
        const twin = await send(item, csrf, signal)

        if (twin) handlers.onTwin(twin)
        else handlers.onSent(item.path)
        break
      } catch (error) {
        if (signal.aborted) return
        if (error instanceof Unauthorized) throw error

        if (error instanceof Refused || attempt >= ATTEMPTS) {
          handlers.onFailed({
            path: item.path,
            reason: error instanceof Error ? error.message : 'failed',
          })
          break
        }

        await new Promise((resolve) => setTimeout(resolve, 250 * attempt))
      }
    }
  }
}

export async function upload(
  sources: { entries?: FileSystemEntry[]; files?: Dropped[] },
  handlers: Handlers,
  csrf: string | null,
  signal: AbortSignal,
) {
  const channel = new Channel<Dropped>(BUFFER)

  const stop = () => channel.close()

  signal.addEventListener('abort', stop, { once: true })

  let fatal: Error | null = null

  const workers = Array.from({ length: WORKERS }, () =>
    drain(channel, handlers, csrf, signal).catch((error: unknown) => {
      fatal = error instanceof Error ? error : new Error(String(error))
      channel.close()
    }),
  )

  try {
    let found = 0

    for (const file of sources.files ?? []) {
      if (channel.shut) break

      found += 1
      handlers.onFound(found)
      await channel.put(file)
    }

    if (sources.entries?.length) {
      await walk(
        sources.entries,
        channel,
        (walked) => handlers.onFound(found + walked),
        signal,
      )
    }
  } finally {
    handlers.onWalked()
    channel.close()
  }

  await Promise.all(workers)

  signal.removeEventListener('abort', stop)

  if (fatal) throw fatal
}
