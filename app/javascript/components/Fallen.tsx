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
          {this.props.what ?? 'This page could not be shown'}
        </div>

        <Text c="dimmed" size="sm" mt="var(--s3)" maw="52ch">
          Your files and catalog are safe. Only this page failed. Try again. If
          it keeps failing, share the message below when you report it.
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
