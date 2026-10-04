import {
  Alert,
  Button,
  Group,
  Modal,
  NumberInput,
  Stack,
  Text,
  Textarea,
  TextInput,
} from '@mantine/core'
import { SaveFeedDocument } from '@xixo/client'
import { useMutation } from '@xixo/client/react'
import { useEffect, useState } from 'react'

export const EVERY = [
  { label: 'by hand', seconds: 0 },
  { label: 'hourly', seconds: 3600 },
  { label: 'daily', seconds: 86400 },
  { label: 'weekly', seconds: 604800 },
]

export interface Feed {
  id: string
  key: string
  title?: string | null
  timeout?: number | null
  schedule?: {
    prompt: string
    interval?: number | null
    turns?: number | null
  } | null
}

interface Props {
  opened: boolean
  onClose: () => void
  feed?: Feed | null
  onSaved: (key: string) => void
}

export function FeedForm({ opened, onClose, feed, onSaved }: Props) {
  const save = useMutation(SaveFeedDocument)

  const [slug, setSlug] = useState('')
  const [name, setName] = useState('')
  const [prompt, setPrompt] = useState('')
  const [interval, setInterval] = useState(0)
  const [turns, setTurns] = useState<number | string>('')
  const [minutes, setMinutes] = useState<number | string>('')
  const [refused, setRefused] = useState<string | null>(null)

  useEffect(() => {
    if (!opened) return

    setSlug(feed?.key.replace(/^\//, '') ?? '')
    setName(feed?.title ?? '')
    setPrompt(feed?.schedule?.prompt ?? '')
    setInterval(feed?.schedule?.interval ?? 0)
    setTurns(feed?.schedule?.turns ?? '')
    setMinutes(feed?.timeout ? Math.round(feed.timeout / 60) : '')
    setRefused(null)
  }, [opened, feed])

  const keep = async () => {
    const { data: answered, error } = await save.attempt({
      id: feed?.id ?? null,
      key: slug,
      title: name.trim() || null,
      prompt,
      interval,
      turns: Number(turns) > 0 ? Number(turns) : null,
      timeout: Number(minutes) > 0 ? Number(minutes) * 60 : null,
    })

    if (!answered?.saveFeed?.feed) {
      setRefused(error?.message ?? 'That feed could not be saved.')
      return
    }

    onClose()
    onSaved(answered.saveFeed.feed.key)
  }

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={feed ? `Edit ${feed.key}` : 'New feed'}
    >
      <Stack gap="var(--s4)">
        <TextInput
          label="Address"
          description="It becomes a path. Letters, numbers and dashes."
          placeholder="buy"
          value={slug}
          onChange={(event) => setSlug(event.currentTarget.value)}
        />

        <TextInput
          label="Name"
          description="What to call it in a list. Left empty, its address does."
          placeholder="Worth buying"
          value={name}
          onChange={(event) => setName(event.currentTarget.value)}
        />

        <Textarea
          label="Prompt"
          description="What it should go and find, in a sentence."
          placeholder="Find things worth buying from my stores."
          autosize
          minRows={3}
          value={prompt}
          onChange={(event) => setPrompt(event.currentTarget.value)}
        />

        <div>
          <Text size="sm" fw={500}>
            Runs
          </Text>
          <Group gap="var(--s2)" mt="var(--s2)">
            {EVERY.map((option) => (
              <button
                key={option.label}
                type="button"
                className="tag"
                data-dot="false"
                data-on={interval === option.seconds}
                aria-pressed={interval === option.seconds}
                style={{ cursor: 'pointer' }}
                onClick={() => setInterval(option.seconds)}
              >
                {option.label}
              </button>
            ))}
          </Group>
        </div>

        {interval > 0 && (
          <NumberInput
            label="Seconds between runs"
            min={60}
            value={interval}
            onChange={(value) => setInterval(Number(value) || 0)}
          />
        )}

        <NumberInput
          label="Turns it may take"
          description="How many times it may think before it gives up. Left empty, six."
          min={1}
          placeholder="6"
          value={turns}
          onChange={setTurns}
        />

        <NumberInput
          label="Minutes it may run"
          description="How long a run may take before it is cut off. It can ask for more, never past a day. Left empty, five."
          min={1}
          max={1440}
          placeholder="5"
          value={minutes}
          onChange={setMinutes}
        />

        {refused && <Alert color="red">{refused}</Alert>}

        <Group justify="flex-end">
          <Button variant="default" onClick={onClose}>
            Cancel
          </Button>
          <Button
            loading={save.loading}
            disabled={!slug || !prompt}
            onClick={keep}
          >
            {feed ? 'Save' : 'Create'}
          </Button>
        </Group>
      </Stack>
    </Modal>
  )
}
