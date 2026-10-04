import {
  Button,
  Group,
  Modal,
  Select,
  Stack,
  Text,
  TextInput,
} from '@mantine/core'
import { IconPackageExport } from '@tabler/icons-react'
import {
  ExportFeedsDocument,
  ResourcesDocument,
  TypesDocument,
} from '@xixo/client'
import { useQuery } from '@xixo/client/react'
import { useEffect, useState } from 'react'
import { pluralOf } from '../looks'
import { useAloud, useSay } from './Say'

interface Props {
  opened: boolean
  onClose: () => void
  type: string | null
  term: string
}

export function Export({ opened, onClose, type, term }: Props) {
  const say = useSay()
  const resources = useQuery(ResourcesDocument, undefined, { skip: !opened })
  const catalog = useQuery(TypesDocument, undefined, { skip: !opened })
  const start = useAloud(ExportFeedsDocument, 'That export could not start.')

  const [destination, setDestination] = useState<string | null>(null)
  const [narrowed, setNarrowed] = useState<string | null>(null)
  const [query, setQuery] = useState('')

  useEffect(() => {
    if (!opened) return

    setDestination(null)
    setNarrowed(type)
    setQuery(term)
  }, [opened, type, term])

  const storage = (resources.data?.resources ?? []).filter((resource) =>
    resource.capabilities.includes('storage'),
  )
  const fallback = storage.find((resource) => resource.defaultStorage)
  const kinds = catalog.data?.types ?? []

  const send = async () => {
    const answered = await start.execute({
      destinationId: destination,
      type: narrowed,
      query: query.trim() || null,
    })

    if (!answered) return

    onClose()
    say({ text: 'The export is running in the background.' })
  }

  return (
    <Modal opened={opened} onClose={onClose} title="Export items">
      <Stack gap="var(--s4)">
        <Text size="sm" c="dimmed">
          Writes a copy of everything that matches into a resource you can reach
          from outside xixo. It runs in the background.
        </Text>

        <Select
          label="Write them to"
          description={
            fallback
              ? `Left alone, they land in ${fallback.key}.`
              : 'This tenant has no default storage, so pick one.'
          }
          placeholder={fallback ? fallback.key : 'Pick a storage resource'}
          value={destination}
          onChange={setDestination}
          clearable
          data={storage.map((resource) => ({
            value: resource.id,
            label: `${resource.key} · ${resource.type}`,
          }))}
        />

        <Select
          label="Of type"
          placeholder="every type"
          value={narrowed}
          onChange={setNarrowed}
          clearable
          data={kinds.map((entry) => ({
            value: entry.type,
            label: `${pluralOf(entry.type)} (${entry.count.toLocaleString()})`,
          }))}
        />

        <TextInput
          label="Matching"
          description="Left empty, everything of that type goes."
          placeholder="a search, the way you would type it in the bar"
          value={query}
          onChange={(event) => setQuery(event.currentTarget.value)}
        />

        <Group justify="flex-end" gap="var(--s2)">
          <Button variant="default" onClick={onClose}>
            Cancel
          </Button>
          <Button
            color="brand"
            loading={start.loading}
            disabled={!destination && !fallback}
            leftSection={<IconPackageExport size={16} />}
            onClick={send}
          >
            Export
          </Button>
        </Group>
      </Stack>
    </Modal>
  )
}
