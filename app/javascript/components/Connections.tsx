import { Alert, Button, Group, Loader, Stack, Text } from '@mantine/core'
import { CatalogDocument } from '@uris-to/client'
import { useQuery } from '@uris-to/client/react'
import { useState } from 'react'
import { usePages } from '../hooks/usePages'
import { TYPE } from '../looks'
import { type Row, Rows } from './Rows'

const PAGE = 40
const LINKED: string[] = [TYPE.file, TYPE.note, TYPE.address]

export function Connections({
  id,
  hidden,
  facet,
  about,
}: {
  id: string
  hidden: ReadonlySet<string>
  facet: boolean
  about?: string
}) {
  const [cursor, setCursor] = useState<string | null>(null)
  const { data, loading, error } = useQuery(CatalogDocument, {
    types: LINKED,
    connectedTo: id,
    topLevel: false,
    after: cursor,
    limit: PAGE,
  })

  const page = data?.feeds
  const [rows] = usePages<Row>(page, cursor)
  const shown = rows.filter((row) => !hidden.has(row.id))
  const next = page?.hasMore ? (page.nextCursor ?? null) : null

  if (error) return <Alert color="red">{error.message}</Alert>

  if (shown.length === 0) {
    if (loading) return <Loader size="sm" color="var(--brass)" />

    return facet ? (
      <Text size="sm" c="dimmed">
        Nothing is filed under this yet.
      </Text>
    ) : null
  }

  return (
    <Stack gap="var(--s3)">
      <div className="label">Connections</div>
      {about && (
        <Text size="sm" c="dimmed">
          {about}
        </Text>
      )}
      <Rows rows={shown} />
      {next !== null && (
        <Group justify="center">
          <Button
            variant="default"
            radius="xl"
            loading={loading}
            onClick={() => setCursor(next)}
          >
            Load more
          </Button>
        </Group>
      )}
    </Stack>
  )
}
