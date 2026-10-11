import { Button, CopyButton, Group, Text } from '@mantine/core'
import { IconCheck, IconCircleDashed } from '@tabler/icons-react'
import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { SetSettingDocument, SettingsDocument, SetupDocument } from 'xixo'
import { useQuery } from 'xixo/react'
import { useAloud, useSay } from './Say'

const SETTING = 'setup_checklist'
const GUIDE = 'https://docs.xixo.network/guides/connect-an-agent/'

export function Setup() {
  const say = useSay()
  const { data } = useQuery(SetupDocument)
  const settings = useQuery(SettingsDocument)
  const hide = useAloud(
    SetSettingDocument,
    'The checklist could not be hidden.',
  )

  const setup = data?.setup
  const hidden =
    settings.data?.settings.find((setting) => setting.key === SETTING)
      ?.value === 'hidden'

  if (!setup || !settings.data || hidden) return null
  if (setup.storage && setup.inference && setup.client) return null

  const command = `claude mcp add --transport http xixo ${window.location.origin}/mcp`
  const left = [setup.storage, setup.inference, setup.client].filter(
    (done) => !done,
  ).length

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
              key: SETTING,
              value: 'hidden',
            })

            if (!answered) return

            settings.refetch()
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
          <Button
            component={Link}
            to="/settings/resources?attach=1"
            size="compact-sm"
            radius="xl"
            variant="default"
          >
            Attach storage
          </Button>
        </Step>

        <Step
          done={setup.inference}
          title="A model server that answers"
          detail="Attach Ollama, LM Studio, or another OpenAI-compatible server so xixo can describe what it keeps and answer questions."
        >
          <Button
            component={Link}
            to="/settings/resources?attach=1"
            size="compact-sm"
            radius="xl"
            variant="default"
          >
            Attach a model server
          </Button>
        </Step>

        <Step
          done={setup.client}
          title="An agent pointed at xixo"
          detail="Add xixo to Claude Code or another MCP client, then sign in when it asks."
        >
          <div className="setup-command">
            <code>{command}</code>
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
