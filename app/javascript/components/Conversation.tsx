import { Button, Group, Stack, Text } from '@mantine/core'
import { IconArrowRight, IconSparkles, IconTag } from '@tabler/icons-react'
import { AskCatalogDocument, AskedDocument } from '@xixo/client'
import { useQuery } from '@xixo/client/react'
import { useEffect, useRef, useState } from 'react'
import { TYPE } from '../looks'
import { RUN_OPEN } from '../runs'
import { AnswerText } from './Answer'
import { Progress } from './FeedHead'
import { type Row, Rows } from './Rows'
import { useAloud } from './Say'
import { Tagger } from './Tagger'

const taggable = (row: Row) => row.type === TYPE.file || row.type === TYPE.note

function DrewOn({ rows, onChanged }: { rows: Row[]; onChanged: () => void }) {
  const [chosen, setChosen] = useState<ReadonlySet<string> | null>(null)
  const held = rows.filter(taggable)

  const toggle = (id: string) =>
    setChosen((now) => {
      const next = new Set(now)
      if (!next.delete(id)) next.add(id)

      return next
    })

  return (
    <Stack gap="var(--s2)">
      <Group justify="space-between">
        <div className="label">What it drew on</div>
        {held.length > 0 && !chosen && (
          <Button
            size="compact-xs"
            variant="subtle"
            color="chalk"
            leftSection={<IconTag size={13} />}
            onClick={() => setChosen(new Set(held.map((row) => row.id)))}
          >
            Tag these
          </Button>
        )}
      </Group>
      <Rows
        rows={rows}
        pick={chosen ? { chosen, toggle, pickable: taggable } : undefined}
      />
      {chosen && (
        <Tagger
          ids={[...chosen]}
          placeholder="Tag the ones you have checked"
          onTagged={() => {
            setChosen(null)
            onChanged()
          }}
          onCancel={() => setChosen(null)}
        />
      )}
    </Stack>
  )
}

export function Conversation({
  feedId,
  onChanged,
}: {
  feedId: string
  onChanged: () => void
}) {
  const [question, setQuestion] = useState('')
  const { data, refetch } = useQuery(AskedDocument, { id: feedId })
  const ask = useAloud(AskCatalogDocument, 'That could not be asked.')

  const turns = [...(data?.feed?.analyses ?? [])]
    .filter((pass) => pass.cause === 'ask')
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
  const answering = turns.some((pass) => RUN_OPEN.has(pass.status))
  const was = useRef(answering)

  useEffect(() => {
    if (!answering) return

    const tick = window.setInterval(() => refetch(), 4000)

    return () => window.clearInterval(tick)
  }, [answering, refetch])

  useEffect(() => {
    if (was.current && !answering) onChanged()
    was.current = answering
  }, [answering, onChanged])

  const submit = async () => {
    const text = question.trim()

    if (!text || answering) return

    const answered = await ask.execute({ question: text, feedId })

    if (!answered?.askCatalog) return

    setQuestion('')
    refetch()
  }

  return (
    <section className="ask">
      <div className="label">The conversation</div>

      <form
        className="ask-bar"
        onSubmit={(event) => {
          event.preventDefault()
          submit()
        }}
      >
        <IconSparkles size={17} stroke={1.7} color="var(--brass)" />
        <input
          value={question}
          onChange={(event) => setQuestion(event.currentTarget.value)}
          placeholder={
            answering
              ? 'Answering — ask the next thing once it lands'
              : 'Ask a follow-up'
          }
          aria-label="Ask a follow-up in this conversation"
          maxLength={500}
          disabled={answering}
        />
        <Button
          type="submit"
          radius="xl"
          color="chalk"
          size="compact-md"
          loading={ask.loading}
          disabled={!question.trim() || answering}
          rightSection={<IconArrowRight size={15} />}
        >
          Ask
        </Button>
      </form>

      {turns.map((pass) => (
        <div key={pass.id} className="ask-answer">
          <div className="ask-question">{pass.question}</div>

          {RUN_OPEN.has(pass.status) ? (
            <Progress
              pass={{
                id: pass.id,
                cause: 'ask',
                status: pass.status,
                turns: pass.turns,
                createdAt: pass.createdAt,
              }}
            />
          ) : pass.status === 'done' && pass.said ? (
            <>
              <AnswerText
                said={pass.said}
                cited={[...(data?.feed?.connected ?? []), ...pass.drewOn]}
              />
              {pass.drewOn.length > 0 && (
                <DrewOn rows={pass.drewOn as Row[]} onChanged={onChanged} />
              )}
            </>
          ) : (
            <Text size="sm" style={{ color: 'var(--bad)' }}>
              {pass.error ?? 'It could not answer that.'}
            </Text>
          )}
        </div>
      ))}
    </section>
  )
}
