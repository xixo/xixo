import { Alert, Button } from '@mantine/core'
import { IconRefresh } from '@tabler/icons-react'

export function Failed({ error, retry }: { error: Error; retry: () => void }) {
  const offline = typeof navigator !== 'undefined' && !navigator.onLine

  return (
    <Alert
      color="red"
      variant="light"
      title={offline ? 'This device is offline' : 'This could not be loaded'}
    >
      <div className="failed">
        <span>
          {offline
            ? 'Try again once it is back online.'
            : error.message.replace(/^\[\w+\]\s*/, '')}
        </span>
        <Button
          size="compact-sm"
          radius="xl"
          variant="default"
          leftSection={<IconRefresh size={14} />}
          onClick={() => retry()}
        >
          Try again
        </Button>
      </div>
    </Alert>
  )
}
