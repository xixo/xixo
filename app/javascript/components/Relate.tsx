import { Button, Loader, Modal, Stack, Text, TextInput } from '@mantine/core'
import { useDebouncedValue } from '@mantine/hooks'
import { useRef, useState } from 'react'
import { CatalogDocument, ConnectFeedsDocument, SearchDocument } from 'xixo'
import { useQuery } from 'xixo/react'
import { LINKED } from '../looks'
import { useAloud, useSay } from './Say'
import { TypeBadge } from './TypeBadge'

const SHOWN = 12

export function Relate({
  item,
  onClose,
  onChanged,
}: {
  item: { id: string; name: string }
  onClose: () => void
  onChanged: () => void
}) {
  const say = useSay()
  const [term, setTerm] = useState('')
  const [query] = useDebouncedValue(term.trim(), 250)
  const changed = useRef(false)
  const [busy, setBusy] = useState<string | null>(null)
  const connect = useAloud(
    ConnectFeedsDocument,
    'Those items could not be related.',
  )

  const held = useQuery(CatalogDocument, {
    types: LINKED,
    connectedTo: item.id,
    topLevel: false,
    after: null,
    limit: 200,
  })
  const found = useQuery(
    SearchDocument,
    { query, types: LINKED, after: null, limit: SHOWN + 1 },
    { skip: query.length === 0 },
  )

  const connected = new Set(
    (held.data?.feeds.nodes ?? []).map((node) => node.id),
  )
  const related = (id: string) => connected.has(id)
  const rows = query
    ? (found.data?.search.nodes ?? [])
        .filter((node) => node.id !== item.id)
        .slice(0, SHOWN)
    : (held.data?.feeds.nodes ?? [])

  const toggle = async (other: {
    id: string
    title?: string | null
    key: string
  }) => {
    const next = !related(other.id)
    const label = other.title ?? other.key

    setBusy(other.id)
    const answered = await connect
      .execute({ id: item.id, otherId: other.id, connected: next })
      .finally(() => setBusy(null))

    if (!answered?.connectFeeds) return

    changed.current = true
    held.refetch()
    say({
      text: next
        ? `${label} is related to ${item.name}.`
        : `${label} is no longer related to ${item.name}.`,
    })
  }

  const close = () => {
    if (changed.current) onChanged()
    onClose()
  }

  return (
    <Modal
      opened
      onClose={close}
      title={`Relate ${item.name} to another item`}
      size="lg"
      radius="md"
    >
      <Stack gap="var(--s4)">
        <TextInput
          id="relate-search"
          data-autofocus
          placeholder="Search for an item by name or what it holds"
          value={term}
          onChange={(event) => setTerm(event.currentTarget.value)}
        />

        {query && found.loading && !found.data && (
          <Loader size="sm" color="var(--accent)" />
        )}

        {!query && rows.length > 0 && <div className="label">Related now</div>}

        {rows.length === 0 && !(query && found.loading) && (
          <Text size="sm" c="dimmed">
            {query
              ? 'Nothing matches that. An item turns up once it has been analyzed.'
              : 'Nothing is related yet. Search for an item to relate it.'}
          </Text>
        )}

        {rows.length > 0 && (
          <ul className="relate-list">
            {rows.map((row) => {
              const on = related(row.id)

              return (
                <li key={row.id} className="relate-row">
                  <TypeBadge type={row.type} mime={row.mime} />
                  <div className="relate-name">
                    <div>{row.title ?? row.key}</div>
                    {row.summary && (
                      <Text size="xs" c="dimmed" lineClamp={1}>
                        {row.summary}
                      </Text>
                    )}
                  </div>
                  <Button
                    size="compact-sm"
                    radius="xl"
                    variant={on ? 'default' : 'light'}
                    loading={busy === row.id}
                    disabled={busy !== null && busy !== row.id}
                    onClick={() => toggle(row)}
                  >
                    {on ? 'Unrelate' : 'Relate'}
                  </Button>
                </li>
              )
            })}
          </ul>
        )}
      </Stack>
    </Modal>
  )
}
