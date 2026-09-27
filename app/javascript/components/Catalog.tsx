import { Alert, Button, Group, Loader, Menu, Stack, Text } from '@mantine/core'
import {
  IconDots,
  IconFilePlus,
  IconFolderPlus,
  IconLayoutGrid,
  IconLayoutList,
  IconLink,
  IconPackageExport,
  IconPlus,
  IconSparkles,
} from '@tabler/icons-react'
import {
  AnalysisProgressedDocument,
  AskCatalogDocument,
  CatalogDocument,
  FeedAnalyzedDocument,
  FeedScheduleDocument,
  FeedsDocument,
  SearchDocument,
  SetSettingDocument,
  SettingsDocument,
  TypesDocument,
} from '@uris-to/client'
import { useQuery, useSubscription } from '@uris-to/client/react'
import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { useEndless } from '../hooks/useEndless'
import { usePages } from '../hooks/usePages'
import { useTitle } from '../hooks/useTitle'
import { KEPT, lookOf, pluralOf, type Short, TYPE, toned } from '../looks'
import { useAdd } from './Add'
import { Export } from './Export'
import { FeedForm } from './FeedForm'
import { FeedHead } from './FeedHead'
import { Lost } from './Lost'
import { type Row, Rows, type View } from './Rows'
import { useAloud, useSay } from './Say'
import { useUploads } from './Uploads'

const PAGE = 40

const VIEWS: View[] = ['list', 'cards']

const VIEW_SETTING = 'catalog_view'

const VIEW_ICONS = { list: IconLayoutList, cards: IconLayoutGrid }

const OPEN = new Set(['queued', 'running'])

function asView(value: string | null | undefined): View {
  return value === 'cards' ? 'cards' : 'list'
}

interface Schedule {
  id: string
  prompt: string
  interval?: number | null
  pausedAt?: string | null
  turns?: number | null
}

interface Feed {
  id: string
  key: string
  title?: string | null
  connectedCount: number
  schedule?: Schedule | null
}

export function Catalog() {
  const { slug } = useParams()
  const [params] = useSearchParams()
  const type = typeFrom(params.get('type'))
  const term = (params.get('q') ?? '').trim()

  const settings = useQuery(SettingsDocument)
  const feeds = useQuery(FeedsDocument, {})
  const save = useAloud(SetSettingDocument, 'That view could not be kept.')
  const [picked, setPicked] = useState<View | null>(null)

  const stored = settings.data?.settings.find(
    (setting) => setting.key === VIEW_SETTING,
  )?.value
  const view = asView(picked ?? stored)

  const pick = (next: View) => {
    setPicked(next)
    save.execute({ key: VIEW_SETTING, value: next })
  }

  const known = (feeds.data?.feeds.nodes ?? []) as Feed[]
  const here = slug
    ? (known.find((feed) => feed.key === `/${slug}`) ?? null)
    : null

  if (slug && !feeds.data) return <Loader size="sm" color="var(--brass)" />
  if (slug && !here) return <Lost />

  return (
    <Listing
      key={`${slug ?? ''} ${type ?? ''} ${term}`}
      type={type}
      term={term}
      feed={here}
      feeds={known}
      view={view}
      onPick={pick}
      onChanged={feeds.refetch}
    />
  )
}

function typeFrom(given: string | null): string | null {
  return given && given in TYPE ? TYPE[given as Short] : null
}

function Listing({
  type,
  term,
  feed,
  feeds,
  view,
  onPick,
  onChanged,
}: {
  type: string | null
  term: string
  feed: Feed | null
  feeds: Feed[]
  view: View
  onPick: (next: View) => void
  onChanged: () => void
}) {
  const searching = term.length > 0

  const [cursor, setCursor] = useState<string | null>(null)
  const { settledAt } = useUploads()
  const { addedAt } = useAdd()

  const catalog = useQuery(
    CatalogDocument,
    {
      types: type ? [type] : feed ? null : KEPT,
      connectedTo: feed?.id ?? null,
      topLevel: !feed,
      after: cursor,
      limit: PAGE,
    },
    { skip: searching },
  )
  const found = useQuery(
    SearchDocument,
    { query: term, types: type ? [type] : KEPT, after: cursor, limit: PAGE },
    { skip: !searching },
  )
  const { data: analyzed } = useSubscription(FeedAnalyzedDocument)
  const { data: progressed } = useSubscription(AnalysisProgressedDocument, {})

  const thinking = useQuery(
    FeedScheduleDocument,
    { key: feed?.key ?? '' },
    { skip: !feed },
  )

  const page = searching ? found.data?.search : catalog.data?.feeds
  const [rows] = usePages<Row>(page, cursor)

  const analyses = thinking.data?.feed?.analyses ?? []

  const streamed = progressed?.analysisProgressed.analysis
  const settled =
    streamed &&
    !OPEN.has(streamed.status) &&
    analyses.some((analysis) => analysis.id === streamed.id)

  useTitle(
    feed ? feed.key : term ? `${term} — search` : type ? pluralOf(type) : null,
  )

  useEffect(() => {
    if (analyzed && !searching) catalog.refetch()
  }, [analyzed, searching, catalog.refetch])

  useEffect(() => {
    if ((settledAt || addedAt) && !searching) {
      setCursor(null)
      catalog.refetch()
    }
  }, [settledAt, addedAt, searching, catalog.refetch])

  useEffect(() => {
    if (!settled) return

    setCursor(null)
    catalog.refetch()
    thinking.refetch()
  }, [settled, catalog.refetch, thinking.refetch])

  const total = searching ? (found.data?.search.total ?? null) : null
  const loading = searching ? found.loading : catalog.loading
  const error = searching ? found.error : catalog.error
  const next = page?.hasMore ? (page.nextCursor ?? null) : null
  const edge = useEndless(
    () => setCursor(next),
    next !== null && !loading && !error,
  )

  return (
    <Stack gap="var(--s5)">
      <Shelf feeds={feeds} here={feed} onChanged={onChanged} />

      {feed && (
        <FeedHead
          feed={feed}
          passes={analyses}
          cap={thinking.data?.feed?.schedule?.turns}
          onChanged={() => {
            onChanged()
            thinking.refetch()
          }}
        />
      )}

      <div className="page-head">
        <div className="eyebrow">
          {searching ? (
            <>
              <span className="figure">{rows.length.toLocaleString()}</span>
              {total !== null && total > rows.length && (
                <>
                  {' of '}
                  <span className="figure">{total.toLocaleString()}</span>
                </>
              )}{' '}
              {total === 1 ? 'match' : 'matches'}
              {type ? ` among ${pluralOf(type)}` : ''}
            </>
          ) : (
            <>
              <span className="figure">{rows.length.toLocaleString()}</span>{' '}
              {type ? pluralOf(type) : rows.length === 1 ? 'item' : 'items'}
              {page?.hasMore ? ' so far' : ''}
              {feed ? ' kept by this feed' : ''}
            </>
          )}
        </div>

        <Group gap="var(--s2)" wrap="nowrap">
          {!feed && <Types />}
          <Switcher view={view} onPick={onPick} />
          {!feed && <Tools type={type} term={term} />}
        </Group>
      </div>

      {error && <Alert color="red">{error.message}</Alert>}

      <Rows
        rows={rows}
        view={view}
        lead={searching && !feed ? <AskAbout term={term} /> : null}
      />

      {loading && rows.length === 0 && (
        <Loader size="sm" color="var(--brass)" />
      )}

      {!loading && rows.length === 0 && (
        <Empty searching={searching} type={type} feed={feed} />
      )}

      {next !== null && (
        <Group justify="center" ref={edge}>
          <Button
            variant="default"
            radius="xl"
            onClick={() => setCursor(next)}
            loading={loading}
          >
            Load more
          </Button>
        </Group>
      )}
    </Stack>
  )
}

// A feed is a saved way of cutting the catalog, so it sits with the catalog
// rather than in a section of its own.
function Shelf({
  feeds,
  here,
  onChanged,
}: {
  feeds: Feed[]
  here: Feed | null
  onChanged: () => void
}) {
  const say = useSay()
  const navigate = useNavigate()
  const [making, setMaking] = useState(false)

  return (
    <div className="shelf">
      <Link
        to="/"
        className="chip"
        data-on={here === null}
        aria-current={here === null ? 'page' : undefined}
      >
        Everything
      </Link>

      {feeds.map((feed) => (
        <Link
          key={feed.id}
          to={feed.key}
          className="chip"
          data-on={feed.id === here?.id}
          aria-current={feed.id === here?.id ? 'page' : undefined}
        >
          {feed.key}
          {feed.schedule?.pausedAt ? (
            <span className="chip-note">paused</span>
          ) : null}
        </Link>
      ))}

      <button
        type="button"
        className="chip chip-new"
        aria-label="New feed"
        onClick={() => setMaking(true)}
      >
        <IconPlus size={14} stroke={2} />
      </button>

      <FeedForm
        opened={making}
        onClose={() => setMaking(false)}
        onSaved={(saved) => {
          say({ text: `${saved} is saved.` })
          onChanged()
          navigate(saved)
        }}
      />
    </div>
  )
}

const MENU: Short[] = ['file', 'note', 'feed', 'tag', 'mime']

function Types() {
  const [params] = useSearchParams()
  const { settledAt } = useUploads()
  const { addedAt } = useAdd()
  const { data, refetch } = useQuery(TypesDocument)

  useEffect(() => {
    if (settledAt || addedAt) refetch()
  }, [settledAt, addedAt, refetch])

  const type = typeFrom(params.get('type'))
  const counts = new Map(
    (data?.types ?? []).map((entry) => [entry.type, entry.count]),
  )
  const kept = KEPT.reduce((sum, held) => sum + (counts.get(held) ?? 0), 0)

  const linkTo = (next: Short | null) => {
    const held = new URLSearchParams(params)

    if (next) held.set('type', next)
    else held.delete('type')

    const query = held.toString()

    return query ? `/?${query}` : '/'
  }

  const dot = (full: string) => (
    <span className="dot" style={toned(lookOf({ type: full }).tone)} />
  )

  return (
    <Menu position="bottom-end" width={230}>
      <Menu.Target>
        <Button
          variant={type ? 'light' : 'default'}
          color="gray"
          size="compact-sm"
          radius="xl"
          leftSection={type ? dot(type) : undefined}
        >
          {type ? pluralOf(type) : 'Files and notes'}
        </Button>
      </Menu.Target>
      <Menu.Dropdown>
        <Menu.Item component={Link} to={linkTo(null)}>
          <Group justify="space-between" gap="var(--s4)">
            <span>files and notes</span>
            <span className="figure">{kept.toLocaleString()}</span>
          </Group>
        </Menu.Item>

        <Menu.Divider />

        {MENU.map((short) => (
          <Menu.Item
            key={short}
            component={Link}
            to={linkTo(TYPE[short] === type ? null : short)}
            leftSection={dot(TYPE[short])}
            disabled={!counts.get(TYPE[short])}
          >
            <Group justify="space-between" gap="var(--s4)">
              <span>{pluralOf(TYPE[short])}</span>
              <span className="figure">
                {(counts.get(TYPE[short]) ?? 0).toLocaleString()}
              </span>
            </Group>
          </Menu.Item>
        ))}
      </Menu.Dropdown>
    </Menu>
  )
}

function Tools({ type, term }: { type: string | null; term: string }) {
  const [exporting, setExporting] = useState(false)

  return (
    <>
      <Export
        opened={exporting}
        onClose={() => setExporting(false)}
        type={type}
        term={term}
      />

      <Menu position="bottom-end" width={210}>
        <Menu.Target>
          <Button
            variant="subtle"
            color="gray"
            size="compact-sm"
            radius="xl"
            aria-label="More"
          >
            <IconDots size={16} stroke={1.8} />
          </Button>
        </Menu.Target>
        <Menu.Dropdown>
          <Menu.Item
            leftSection={<IconPackageExport size={16} stroke={1.6} />}
            onClick={() => setExporting(true)}
          >
            Export these…
          </Menu.Item>
        </Menu.Dropdown>
      </Menu>
    </>
  )
}

function Switcher({
  view,
  onPick,
}: {
  view: View
  onPick: (next: View) => void
}) {
  return (
    <div className="switcher">
      {VIEWS.map((value) => {
        const Icon = VIEW_ICONS[value]

        return (
          <button
            key={value}
            type="button"
            data-on={view === value}
            aria-pressed={view === value}
            aria-label={value === 'cards' ? 'Cards' : 'List'}
            onClick={() => onPick(value)}
          >
            <Icon size={16} stroke={1.7} />
          </button>
        )
      })}
    </div>
  )
}

function AskAbout({ term }: { term: string }) {
  const navigate = useNavigate()
  const ask = useAloud(AskCatalogDocument, 'That could not be asked.')

  return (
    <button
      type="button"
      className="entry entry-ask"
      data-ask-row
      disabled={ask.loading}
      onKeyDown={(event) => {
        if (event.key !== 'ArrowUp' && event.key !== 'Escape') return

        event.preventDefault()
        document.querySelector<HTMLInputElement>('.hunt input')?.focus()
      }}
      onClick={async () => {
        const answered = await ask.execute({ question: term })
        const held = answered?.askCatalog

        if (held) navigate(`/items/${held.feed.id}`)
      }}
    >
      <span className="entry-ask-mark">
        {ask.loading ? (
          <Loader size="xs" color="var(--brass)" />
        ) : (
          <IconSparkles size={20} stroke={1.7} />
        )}
      </span>
      <div style={{ minWidth: 0 }}>
        <div className="entry-title">Ask about {term}</div>
        <div className="entry-summary">
          Answered from what you keep and the web, and kept as a note you can go
          on asking in.
        </div>
      </div>
      <span className="tag" data-dot="false">
        ask
      </span>
    </button>
  )
}

function Empty({
  searching,
  type,
  feed,
}: {
  searching: boolean
  type: string | null
  feed: Feed | null
}) {
  const { add } = useUploads()
  const { open } = useAdd()
  const picker = useRef<HTMLInputElement>(null)
  const folders = useRef<HTMLInputElement>(null)

  if (searching) {
    return (
      <Text c="dimmed" size="sm">
        Nothing matches that yet. An item turns up here once it has been
        analyzed or you have written a note on it, so anything still waiting on
        both will not.
      </Text>
    )
  }

  if (feed) {
    return (
      <div className="panel" style={{ padding: 'var(--s6)' }}>
        <Text c="dimmed" size="sm">
          Nothing kept yet. What a run connects to this feed shows up here.
        </Text>
      </div>
    )
  }

  return (
    <div
      className="panel"
      style={{ padding: 'var(--s7) var(--s6)', textAlign: 'center' }}
    >
      <div
        style={{
          fontSize: 'var(--t-title)',
          fontWeight: 600,
          letterSpacing: '-0.02em',
          color: 'var(--soft)',
        }}
      >
        {type ? `No ${pluralOf(type)} yet` : 'Nothing kept yet'}
      </div>
      <Text c="dimmed" size="sm" mt="var(--s3)" mx="auto" maw="46ch">
        Drop a file or a whole folder anywhere on this page, paste an address or
        a screenshot, or sync a resource and it will fill up on its own.
      </Text>

      <input
        ref={picker}
        type="file"
        multiple
        hidden
        onChange={(event) => {
          if (event.currentTarget.files) add(event.currentTarget.files)
          event.currentTarget.value = ''
        }}
      />

      <input
        ref={folders}
        type="file"
        multiple
        hidden
        {...{ webkitdirectory: '' }}
        onChange={(event) => {
          if (event.currentTarget.files) add(event.currentTarget.files)
          event.currentTarget.value = ''
        }}
      />

      <Group justify="center" gap="var(--s3)" mt="var(--s5)">
        <Button
          radius="xl"
          color="chalk"
          leftSection={<IconFilePlus size={16} />}
          onClick={() => picker.current?.click()}
        >
          Choose files
        </Button>
        <Button
          radius="xl"
          variant="default"
          leftSection={<IconFolderPlus size={16} />}
          onClick={() => folders.current?.click()}
        >
          Choose a folder
        </Button>
        <Button
          radius="xl"
          variant="default"
          leftSection={<IconLink size={16} />}
          onClick={() => open()}
        >
          Add a link or a note
        </Button>
      </Group>
    </div>
  )
}
