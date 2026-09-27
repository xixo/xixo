import { Button, Loader, Tooltip } from '@mantine/core'
import type { Account } from '@masks/client'
import { IconLink, IconSearch } from '@tabler/icons-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  Link,
  Navigate,
  Route,
  Routes,
  useLocation,
  useNavigate,
  useSearchParams,
} from 'react-router-dom'
import { asUrl, type Intent, intentFor, shortly } from '../add'
import { useSession } from '../hooks/useSession'
import { useTitle } from '../hooks/useTitle'
import { AddProvider, useAdd } from './Add'
import { Audit } from './Audit'
import { Catalog } from './Catalog'
import { Cycle } from './Cycle'
import { Face } from './Face'
import { Fallen } from './Fallen'
import { ItemDetail } from './ItemDetail'
import { Lost } from './Lost'
import { Mark } from './Mark'
import { Resources } from './Resources'
import { Runs } from './Runs'
import { SayProvider } from './Say'
import { Settings, SignedIn } from './Settings'
import { UploadsProvider } from './Uploads'

const VERBS: [string, string][] = [
  ['make', 'doc'],
  ['see', 'image'],
  ['watch', 'calendar'],
  ['read', 'pdf'],
  ['write', 'text'],
  ['send', 'email'],
  ['buy', 'pkpass'],
  ['share', 'contact'],
  ['keep', 'file'],
]

export function App() {
  const { account, status, loading, login, logout, logoutEverywhere, connect } =
    useSession()

  if (loading) {
    return (
      <div className="gate">
        <Loader color="var(--brass)" />
      </div>
    )
  }

  if (!account) {
    return (
      <Gate
        unconnected={status?.state === 'handshake_required'}
        enter={status?.state === 'handshake_required' ? connect : login}
      />
    )
  }

  return (
    <SayProvider>
      <UploadsProvider>
        <AddProvider>
          <Shell
            account={account}
            who={account.nickname ?? account.name ?? account.email ?? 'you'}
            tenant={account.tenant?.name}
            logout={logout}
            logoutEverywhere={logoutEverywhere}
          />
        </AddProvider>
      </UploadsProvider>
    </SayProvider>
  )
}

function Gate({
  unconnected,
  enter,
}: {
  unconnected: boolean
  enter: () => void
}) {
  useTitle('Sign in')

  const [verb, setVerb] = useState(VERBS[0][0])

  return (
    <div className="gate">
      <div className="gate-inner">
        <div className="gate-mark">
          <Mark size={92} />
        </div>

        <p className="gate-line">
          <span className="wordmark">uris.to</span>/
          <Cycle words={VERBS} onChange={setVerb} />
        </p>

        <p className="gate-tagline">Yours to {verb}</p>

        <Button
          mt="var(--s6)"
          size="md"
          radius="xl"
          color="chalk"
          onClick={enter}
          styles={{ root: { fontWeight: 600, paddingInline: 'var(--s5)' } }}
        >
          {unconnected ? 'Get started…' : 'Sign in'}
        </Button>
      </div>
    </div>
  )
}

function Shell({
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
  const location = useLocation()

  return (
    <div className="shell">
      <header className="shell-head">
        <Link to="/" className="mark-link" aria-label="Catalog">
          <Mark />
        </Link>

        <Hunt />

        <Tooltip label={who} openDelay={400}>
          <Link
            to="/settings"
            className="head-icon head-face"
            aria-label={`${who} — settings`}
            aria-current={
              location.pathname.startsWith('/settings') ? 'page' : undefined
            }
          >
            <Face account={account} />
          </Link>
        </Tooltip>
      </header>

      <main className="shell-main">
        <Fallen key={location.pathname}>
          <Routes>
            <Route path="/" element={<Catalog />} />
            <Route path="/items/:id" element={<ItemDetail />} />
            <Route path="/settings" element={<Settings />}>
              <Route index element={<Navigate to="account" replace />} />
              <Route
                path="account"
                element={
                  <SignedIn
                    account={account}
                    who={who}
                    tenant={tenant}
                    logout={logout}
                    logoutEverywhere={logoutEverywhere}
                  />
                }
              />
              <Route path="resources" element={<Resources />} />
              <Route path="resources/:id" element={<Resources />} />
              <Route path="runs" element={<Runs />} />
              <Route path="activity" element={<Audit />} />
            </Route>
            <Route path="/:slug" element={<Catalog />} />
            <Route path="*" element={<Lost />} />
          </Routes>
        </Fallen>
      </main>
    </div>
  )
}

const SEARCH_PAUSE = 250

const OFFERS: { intent: Intent; what: string; where: string }[] = [
  { intent: 'snapshot', what: 'Keep the page', where: 'as it looks now' },
  { intent: 'fetch', what: 'Keep the file', where: 'at that address' },
]

// The same box searches and adds. Anything with a space in it is a search and
// nothing else; the moment what is typed reads as an address, the two ways of
// keeping it are offered under the bar and Enter takes the likelier one.
function Hunt() {
  const [params, setParams] = useSearchParams()
  const navigate = useNavigate()
  const { keepUrl, busy } = useAdd()
  const term = params.get('q') ?? ''
  const [draft, setDraft] = useState(term)
  const [wanted, setWanted] = useState<Intent | null>(null)
  const [said, setSaid] = useState<string | null>(null)
  const box = useRef<HTMLInputElement | null>(null)
  const sought = useRef(term)

  useEffect(() => {
    if (term === sought.current) return

    sought.current = term
    setDraft(term)
  }, [term])

  useEffect(() => {
    const reach = (event: KeyboardEvent) => {
      if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) {
        return
      }

      const on = event.target as HTMLElement | null

      if (on?.isContentEditable) return
      if (on && /^(INPUT|TEXTAREA|SELECT)$/.test(on.tagName)) return

      event.preventDefault()
      box.current?.focus()
      box.current?.select()
    }

    window.addEventListener('keydown', reach)

    return () => window.removeEventListener('keydown', reach)
  }, [])

  const found = asUrl(draft)
  const intent = wanted ?? (found ? intentFor(found) : 'snapshot')
  const offering = found !== null && said === null

  const search = useCallback(
    (text: string) => {
      const next = new URLSearchParams(window.location.search)

      if (text) next.set('q', text)
      else next.delete('q')

      sought.current = text

      if (window.location.pathname === '/') setParams(next, { replace: true })
      else navigate(`/?${next.toString()}`)
    },
    [setParams, navigate],
  )

  useEffect(() => {
    const text = draft.trim()

    if (found || text === sought.current) return

    const pause = window.setTimeout(() => search(text), SEARCH_PAUSE)

    return () => window.clearTimeout(pause)
  }, [draft, found, search])

  const keep = async (taking: Intent) => {
    const outcome = await keepUrl(draft, taking)

    setSaid(
      outcome.ok
        ? `${outcome.added.label} — ${outcome.added.detail}`
        : outcome.refused,
    )

    if (outcome.ok) setDraft('')

    window.setTimeout(() => setSaid(null), 4000)
  }

  return (
    <form
      className="hunt"
      onSubmit={(event) => {
        event.preventDefault()

        if (found) keep(intent)
        else search(draft.trim())
      }}
    >
      {found ? (
        <IconLink size={16} stroke={1.8} color="var(--brass)" />
      ) : (
        <IconSearch size={16} stroke={1.8} color="var(--muted)" />
      )}

      <input
        ref={box}
        value={draft}
        onChange={(event) => {
          setDraft(event.currentTarget.value)
          setWanted(null)
          setSaid(null)
        }}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            setDraft('')
            event.currentTarget.blur()
            return
          }

          if (!offering) return

          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault()
            setWanted(intent === 'snapshot' ? 'fetch' : 'snapshot')
          }
        }}
        placeholder="Search, ask, or paste an address"
        aria-label="Search everything you own, or paste an address"
      />

      {!draft && <kbd className="hunt-key">/</kbd>}

      {term && !found && (
        <Button
          variant="subtle"
          color="gray"
          size="compact-xs"
          onClick={() => {
            const next = new URLSearchParams(params)
            next.delete('q')
            setDraft('')
            setParams(next)
          }}
        >
          Clear
        </Button>
      )}

      {said && <div className="hunt-drop hunt-said">{said}</div>}

      {offering && (
        <div className="hunt-drop">
          {OFFERS.map((offer) => (
            <button
              key={offer.intent}
              type="button"
              className="hunt-row"
              data-on={intent === offer.intent}
              disabled={busy}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => keep(offer.intent)}
            >
              <span className="hunt-what">{offer.what}</span>
              <span className="hunt-address">{shortly(found)}</span>
              <span className="hunt-where">{offer.where}</span>
            </button>
          ))}
        </div>
      )}
    </form>
  )
}
