import { Button, Group, Text } from '@mantine/core'
import { IconDatabase, IconLayoutGrid, IconSettings } from '@tabler/icons-react'
import { Link, useLocation } from 'react-router-dom'
import { useTitle } from '../hooks/useTitle'

const WAYS = [
  { to: '/', label: 'Catalog', icon: IconLayoutGrid },
  { to: '/settings/resources', label: 'Resources', icon: IconDatabase },
  { to: '/settings', label: 'Settings', icon: IconSettings },
]

export function Lost() {
  const { pathname } = useLocation()

  useTitle('Nothing here')

  return (
    <div className="fallen">
      <div className="fallen-word">Nothing lives here</div>

      <Text c="dimmed" size="sm" mt="var(--s3)" maw="52ch">
        <span className="mono" style={{ color: 'var(--soft)' }}>
          {pathname}
        </span>{' '}
        is not an address xixo knows. It may have been a feed that was never
        made or has since been deleted, or a link that outlived the thing it
        pointed at.
      </Text>

      <Group gap="var(--s3)" mt="var(--s5)">
        {WAYS.map(({ to, label, icon: Icon }) => (
          <Button
            key={to}
            component={Link}
            to={to}
            radius="xl"
            variant={to === '/' ? 'filled' : 'default'}
            color="chalk"
            leftSection={<Icon size={16} stroke={1.6} />}
          >
            {label}
          </Button>
        ))}
      </Group>
    </div>
  )
}
