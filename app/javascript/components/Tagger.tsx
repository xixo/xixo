import { Autocomplete, Button } from '@mantine/core'
import { IconTag } from '@tabler/icons-react'
import { TagFeedsDocument, TagsDocument } from '@xixo/client'
import { useQuery } from '@xixo/client/react'
import { useMemo, useState } from 'react'
import { useAloud, useSay } from './Say'

export function Tagger({
  ids,
  onTagged,
  onCancel,
  placeholder = 'Add a tag',
}: {
  ids: readonly string[]
  onTagged: () => void
  onCancel?: () => void
  placeholder?: string
}) {
  const [tag, setTag] = useState('')
  const say = useSay()
  const tagging = useAloud(TagFeedsDocument, 'That could not be tagged.')
  const name = tag.trim()
  const { data, refetch } = useQuery(TagsDocument)
  const known = useMemo(
    () => (data?.feeds.nodes ?? []).map((held) => held.key),
    [data],
  )

  const submit = async () => {
    if (!name || ids.length === 0) return

    const answered = await tagging.execute({ ids: [...ids], tag: name })

    if (!answered?.tagFeeds) return

    setTag('')
    refetch()
    say({
      text: `${ids.length === 1 ? 'Tagged' : `Tagged ${ids.length} items`} ${name}.`,
    })
    onTagged()
  }

  return (
    <form
      className="tagger"
      onSubmit={(event) => {
        event.preventDefault()
        submit()
      }}
    >
      <IconTag size={15} stroke={1.7} color="var(--brass)" />
      <Autocomplete
        className="tagger-field"
        variant="unstyled"
        size="xs"
        value={tag}
        onChange={setTag}
        data={known}
        limit={8}
        maxLength={100}
        placeholder={placeholder}
        aria-label={placeholder}
        comboboxProps={{ withinPortal: true }}
      />
      <Button
        type="submit"
        size="compact-sm"
        color="chalk"
        loading={tagging.loading}
        disabled={!name || ids.length === 0}
      >
        {ids.length > 1 ? `Tag ${ids.length}` : 'Tag'}
      </Button>
      {onCancel && (
        <Button
          type="button"
          size="compact-sm"
          variant="subtle"
          color="gray"
          onClick={onCancel}
        >
          Cancel
        </Button>
      )}
    </form>
  )
}
