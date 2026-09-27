import { Alert, Button, Group, Loader, Stack } from '@mantine/core'
import type { Account } from '@masks/client'
import {
  IconActivity,
  IconArrowUpRight,
  IconDatabase,
  IconProgressCheck,
  IconUser,
} from '@tabler/icons-react'
import { SetSettingDocument, SettingsDocument } from '@uris-to/client'
import { useQuery } from '@uris-to/client/react'
import { Link, Outlet, useLocation } from 'react-router-dom'
import { useTitle } from '../hooks/useTitle'
import { Face } from './Face'
import { useAloud } from './Say'

const TABS = [
  { to: '/settings/account', label: 'Account', icon: IconUser },
  { to: '/settings/resources', label: 'Resources', icon: IconDatabase },
  { to: '/settings/runs', label: 'Runs', icon: IconProgressCheck },
  { to: '/settings/activity', label: 'Activity', icon: IconActivity },
]

export function Settings() {
  const { pathname } = useLocation()

  return (
    <div className="settings">
      <nav className="subnav" aria-label="Settings">
        {TABS.map(({ to, label, icon: Icon }) => (
          <Link
            key={to}
            to={to}
            className="subnav-link"
            aria-current={pathname.startsWith(to) ? 'page' : undefined}
          >
            <Icon size={16} stroke={1.6} />
            {label}
          </Link>
        ))}
      </nav>

      <Outlet />
    </div>
  )
}

export function SignedIn({
  account,
  who,
  tenant,
  logout,
  logoutEverywhere,
}: {
  account: Account
  who: string
  tenant?: string | null
  logout: () => void
  logoutEverywhere: () => void
}) {
  useTitle('Account')

  const profile = (account as Account & { account_url?: string }).account_url
  const named = account.name ?? who
  const also = [
    account.nickname && account.nickname !== named
      ? `@${account.nickname}`
      : null,
    account.email,
  ].filter(Boolean)

  return (
    <Stack gap="var(--s5)">
      <div className="eyebrow">Who you are signed in as</div>

      <div className="profile">
        <Face account={account} size={56} />

        <div className="profile-who">
          <div className="profile-name">{named}</div>
          {also.length > 0 && (
            <div className="profile-also">{also.join(' · ')}</div>
          )}
          <div className="profile-note">
            {tenant
              ? `Signed in to ${tenant}. Your name, photo, password and passkeys live in masks, not here.`
              : 'Your name, photo, password and passkeys live in masks, not here.'}
          </div>
        </div>

        {profile && (
          <Button
            component="a"
            href={profile}
            target="_blank"
            rel="noreferrer"
            radius="xl"
            color="chalk"
            rightSection={<IconArrowUpRight size={16} stroke={1.8} />}
          >
            Manage account
          </Button>
        )}
      </div>

      <div className="panel">
        <div className="setting">
          <div>
            <div className="setting-name">Sign out</div>
            <div className="setting-note">
              Here only, or everywhere masks has signed you in.
            </div>
          </div>

          <Group gap="var(--s2)" wrap="nowrap">
            <Button size="xs" radius="xl" variant="default" onClick={logout}>
              Sign out
            </Button>
            <Button
              size="xs"
              radius="xl"
              variant="subtle"
              color="gray"
              onClick={logoutEverywhere}
            >
              Everywhere
            </Button>
          </Group>
        </div>
      </div>

      <Preferences />
    </Stack>
  )
}

const GROUPS = [
  { level: 'personal', heading: null },
  { level: 'shared', heading: 'How uris behaves for everyone here' },
  { level: 'server', heading: 'Only for administrators' },
]

function Preferences() {
  const { data, loading, error, refetch } = useQuery(SettingsDocument)
  const save = useAloud(SetSettingDocument, 'That could not be changed.')

  const settings = data?.settings ?? []
  const stale = /does not carry settings:/.test(error?.message ?? '')

  return (
    <Stack gap="var(--s5)">
      <div className="eyebrow">How uris behaves for you</div>

      {error &&
        (stale ? (
          <Alert
            color="yellow"
            title="This sign-in is older than these settings"
          >
            Your token was minted before uris asked for the settings scopes, so
            it does not carry them. Sign out and back in and they will be there.
          </Alert>
        ) : (
          <Alert color="red">{error.message}</Alert>
        ))}

      {loading && !data && <Loader size="sm" color="var(--brass)" />}

      {GROUPS.map(({ level, heading }) => {
        const held = settings.filter((setting) => setting.level === level)

        if (held.length === 0) return null

        return (
          <Stack key={level} gap="var(--s3)">
            {heading && <div className="eyebrow">{heading}</div>}
            <div className="panel">
              {held.map((setting) => (
                <div className="setting" key={setting.key}>
                  <div>
                    <div className="setting-name">{setting.label}</div>
                    {setting.note && (
                      <div className="setting-note">{setting.note}</div>
                    )}
                  </div>

                  <Choice
                    allowed={setting.allowed}
                    value={setting.value}
                    onPick={async (next) => {
                      await save.execute({ key: setting.key, value: next })
                      refetch()
                    }}
                  />
                </div>
              ))}
            </div>
          </Stack>
        )
      })}
    </Stack>
  )
}

function Choice({
  allowed,
  value,
  onPick,
}: {
  allowed: readonly string[]
  value: string
  onPick: (next: string) => void
}) {
  return (
    <div className="switcher" data-wide="true">
      {allowed.map((option) => (
        <button
          key={option}
          type="button"
          data-on={value === option}
          aria-pressed={value === option}
          onClick={() => onPick(option)}
        >
          {/^\d+$/.test(option) ? `${option}px` : option}
        </button>
      ))}
    </div>
  )
}
