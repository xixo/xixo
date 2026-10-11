import { Button, Code, CopyButton, Group, Text } from '@mantine/core'
import { IconCheck, IconCircleDashed } from '@tabler/icons-react'
import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { SetSettingDocument, SetupDocument } from 'xixo'
import { useQuery } from 'xixo/react'
import { useAloud, useSay } from './Say'

export const SETUP_SETTING = 'setup_checklist'
const GUIDE = 'https://docs.xixo.network/guides/connect-an-agent/'

export function Setup({ onHidden }: { onHidden: () => void }) {
  const say = useSay()
  const { data } = useQuery(SetupDocument)
  const hide = useAloud(
    SetSettingDocument,
    'The checklist could not be hidden.',
  )

  const setup = data?.setup
  if (!setup) return null

  const left = [setup.storage, setup.inference, setup.client].filter(
    (done) => !done,
  ).length
  if (left === 0) return null

  const command = `claude mcp add --transport http xixo ${window.location.origin}/mcp`

  return (
    <section className="panel setup" aria-labelledby="setup-heading">
      <div className="setup-head">
        <div>
          <div className="label" id="setup-heading">
            Getting set up
          </div>
          <Text size="sm" c="dimmed">
            {left === 1 ? 'One thing is left.' : `${left} things are left.`}
          </Text>
        </div>
        <Button
          size="compact-sm"
          radius="xl"
          variant="subtle"
          color="gray"
          loading={hide.loading}
          onClick={async () => {
            const answered = await hide.execute({
              key: SETUP_SETTING,
              value: 'hidden',
            })

            if (!answered) return

            onHidden()
            say({ text: 'The checklist is hidden. Settings brings it back.' })
          }}
        >
          Hide
        </Button>
      </div>

      <ol className="setup-steps">
        <Step
          done={setup.storage}
          title="Somewhere to keep what you drop"
          detail="Attach a folder, an S3 bucket, or a WebDAV share, and make it the default place files land."
        >
          <Attach>Attach storage</Attach>
        </Step>

        <Step
          done={setup.inference}
          title="A model server that answers"
          detail="Attach Ollama, LM Studio, or another OpenAI-compatible server so xixo can describe what it keeps and answer questions."
        >
          <Attach>Attach a model server</Attach>
        </Step>

        <Step
          done={setup.client}
          title="An agent pointed at xixo"
          detail="Add xixo to Claude Code or another MCP client, then sign in when it asks."
        >
          <div className="setup-command">
            <Code>{command}</Code>
            <CopyButton value={command}>
              {({ copied, copy }) => (
                <Button
                  size="compact-sm"
                  radius="xl"
                  variant="default"
                  onClick={copy}
                >
                  {copied ? 'Copied' : 'Copy'}
                </Button>
              )}
            </CopyButton>
          </div>
          <Text size="sm">
            <a href={GUIDE} target="_blank" rel="noreferrer">
              Other clients
            </a>
          </Text>
        </Step>
      </ol>
    </section>
  )
}

function Step({
  done,
  title,
  detail,
  children,
}: {
  done: boolean
  title: string
  detail: string
  children: ReactNode
}) {
  return (
    <li className="setup-step" data-done={done}>
      {done ? (
        <IconCheck size={18} color="var(--ok)" aria-label="Done" />
      ) : (
        <IconCircleDashed size={18} color="var(--muted)" aria-label="To do" />
      )}
      <div className="setup-body">
        <div className="setup-title">{title}</div>
        {!done && (
          <>
            <Text size="sm" c="dimmed">
              {detail}
            </Text>
            <Group gap="var(--s2)">{children}</Group>
          </>
        )}
      </div>
    </li>
  )
}

function Attach({ children }: { children: ReactNode }) {
  return (
    <Button
      component={Link}
      to="/settings/resources?attach=1"
      size="compact-sm"
      radius="xl"
      variant="default"
    >
      {children}
    </Button>
  )
}
