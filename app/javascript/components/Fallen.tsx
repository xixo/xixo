import { Button, Code, Group, Text } from '@mantine/core'
import { IconRefresh } from '@tabler/icons-react'
import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props {
  children: ReactNode
  what?: string
}

interface State {
  fell: Error | null
}

export class Fallen extends Component<Props, State> {
  state: State = { fell: null }

  static getDerivedStateFromError(fell: Error): State {
    return { fell }
  }

  componentDidCatch(fell: Error, where: ErrorInfo) {
    console.error(fell, where.componentStack)
  }

  render() {
    const { fell } = this.state

    if (!fell) return this.props.children

    return (
      <div className="fallen">
        <div className="fallen-word">
          {this.props.what ?? 'This page fell over'}
        </div>

        <Text c="dimmed" size="sm" mt="var(--s3)" maw="52ch">
          Nothing was lost — the failure is in what you are looking at, not in
          what you own. Try again, and if it keeps happening the message below
          is the useful part.
        </Text>

        <Code block mt="var(--s4)" className="fallen-why">
          {fell.message}
        </Code>

        <Group gap="var(--s3)" mt="var(--s5)">
          <Button
            radius="xl"
            color="brand"
            leftSection={<IconRefresh size={16} />}
            onClick={() => this.setState({ fell: null })}
          >
            Try again
          </Button>
          <Button
            radius="xl"
            variant="default"
            onClick={() => window.location.assign('/')}
          >
            Back to the catalog
          </Button>
        </Group>
      </div>
    )
  }
}
