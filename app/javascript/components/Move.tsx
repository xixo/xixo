import {
  Button,
  Group,
  Modal,
  Progress,
  Select,
  Stack,
  Text,
  TextInput,
} from '@mantine/core'
import { IconArrowsMove } from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import {
  CancelRunDocument,
  MoveFilesDocument,
  MoveProgressedDocument,
  MoveRunDocument,
  ResourcesDocument,
} from 'xixo'
import { useQuery, useSubscription } from 'xixo/react'
import { movedSoFar, share } from '../moving'
import { RUN_OPEN } from '../runs'
import { useAloud } from './Say'

export type Moving =
  | { kind: 'folder'; source: { id: string; key: string } }
  | { kind: 'selection'; type: string | null; term: string }
  | { kind: 'feed'; id: string; name: string }

interface Props {
  moving: Moving | null
  onClose: () => void
}

function titled(moving: Moving) {
  if (moving.kind === 'folder') return `Move files out of ${moving.source.key}`
  if (moving.kind === 'feed') return `Move ${moving.name}`

  return 'Move these files'
}

export function Move({ moving, onClose }: Props) {
  const opened = moving !== null
  const resources = useQuery(ResourcesDocument, undefined, { skip: !opened })
  const start = useAloud(MoveFilesDocument, 'That move could not start.')

  const [destination, setDestination] = useState<string | null>(null)
  const [path, setPath] = useState('')
  const [into, setInto] = useState('')
  const [run, setRun] = useState<string | null>(null)

  useEffect(() => {
    if (!opened) return

    setDestination(null)
    setPath('')
    setInto('')
    setRun(null)
  }, [opened])

  if (!moving) return null

  const source = moving.kind === 'folder' ? moving.source.id : null
  const folders = (resources.data?.resources ?? []).filter(
    (resource) => resource.movable && resource.id !== source,
  )

  const send = async () => {
    if (!destination) return

    const answered = await start.execute({
      destinationId: destination,
      into: into.trim() || null,
      ...(moving.kind === 'folder'
        ? { sourceId: moving.source.id, path: path.trim() || null }
        : moving.kind === 'feed'
          ? { feedIds: [moving.id] }
          : { type: moving.type, query: moving.term.trim() || null }),
    })

    const started = answered?.moveFiles?.run.id
    if (started) setRun(started)
  }

  return (
    <Modal opened={opened} onClose={onClose} title={titled(moving)}>
      {run ? (
        <Following id={run} onClose={onClose} />
      ) : (
        <Stack gap="var(--s4)">
          {moving.kind === 'folder' && (
            <TextInput
              label="Folder or file"
              description={`Left empty, everything in ${moving.source.key} moves.`}
              placeholder="Photos/2019"
              value={path}
              onChange={(event) => setPath(event.currentTarget.value)}
            />
          )}

          <Select
            label="Move to"
            placeholder={
              folders.length > 0 ? 'Pick a folder' : 'No folder takes files yet'
            }
            description={
              folders.length > 0
                ? undefined
                : 'A folder takes files when its machine shares it writable and may write into it.'
            }
            value={destination}
            onChange={setDestination}
            disabled={folders.length === 0}
            data={folders.map((resource) => ({
              value: resource.id,
              label: `${resource.key} · ${String(resource.settings.folder ?? '')}`,
            }))}
          />

          <TextInput
            label="Into"
            description="A folder inside it. Left empty, the files land at its top."
            placeholder="Archive"
            value={into}
            onChange={(event) => setInto(event.currentTarget.value)}
          />

          <Group justify="flex-end" gap="var(--s2)">
            <Button variant="default" onClick={onClose}>
              Cancel
            </Button>
            <Button
              color="brand"
              loading={start.loading}
              disabled={!destination}
              leftSection={<IconArrowsMove size={16} />}
              onClick={send}
            >
              Move
            </Button>
          </Group>
        </Stack>
      )}
    </Modal>
  )
}

function Following({ id, onClose }: { id: string; onClose: () => void }) {
  const asked = useQuery(MoveRunDocument, { id })
  const { data } = useSubscription(MoveProgressedDocument, { id })
  const cancel = useAloud(
    CancelRunDocument,
    'That move could not be cancelled.',
  )
  const run = data?.runProgressed.run ?? asked.data?.run
  const moved = run?.moved
  const running = !run || RUN_OPEN.has(run.status)

  return (
    <Stack gap="var(--s4)">
      <Progress value={share(moved)} animated={running} aria-label="Moved" />
      <Text size="sm">{movedSoFar(moved)}</Text>

      {run?.status === 'done' && <Text size="sm">Every file moved.</Text>}
      {run?.error && (
        <Text size="sm" c="red">
          {run.error}
        </Text>
      )}

      <Text size="sm" c="dimmed">
        The move keeps going when you close this. Its run on the folder it moves
        into shows how it went.
      </Text>

      <Group justify="flex-end" gap="var(--s2)">
        {running && (
          <Button
            variant="default"
            color="red"
            loading={cancel.loading}
            onClick={() => cancel.execute({ id })}
          >
            Stop the move
          </Button>
        )}
        <Button color="brand" onClick={onClose}>
          Close
        </Button>
      </Group>
    </Stack>
  )
}
