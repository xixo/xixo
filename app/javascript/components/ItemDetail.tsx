import {
  Alert,
  Button,
  Group,
  Loader,
  Menu,
  Modal,
  Stack,
  Text,
  Textarea,
} from '@mantine/core'
import {
  IconArrowLeft,
  IconArrowRight,
  IconChevronDown,
  IconCut,
  IconDots,
  IconEraser,
  IconNote,
  IconPencil,
  IconRefresh,
  IconSparkles,
  IconTag,
  IconX,
} from '@tabler/icons-react'
import {
  type CSSProperties,
  Fragment,
  type ReactNode,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import {
  AnalyzeFeedDocument,
  AskCatalogDocument,
  FeedDetailDocument,
  ForgetFeedDocument,
  NoteFeedDocument,
  RenameFeedDocument,
  SetFeedLifetimeDocument,
  SplitReferenceDocument,
  TagFeedsDocument,
} from 'xixo'
import { useQuery } from 'xixo/react'
import { useTitle } from '../hooks/useTitle'
import { hrefFor, lookOf, TYPE, toned } from '../looks'
import { Connections } from './Connections'
import { Conversation } from './Conversation'
import { OneLine } from './OneLine'
import { Passes, placementOf, why } from './Passes'
import { Readout } from './Readout'
import { Rows } from './Rows'
import { useAloud, useSay } from './Say'
import { Sure } from './Sure'
import { Tagger } from './Tagger'
import { Thumb } from './Thumb'
import { TypeBadge } from './TypeBadge'

const FACETS = new Set<string>([TYPE.tag, TYPE.mime])

const ABOUT: Record<string, string> = {
  [TYPE.tag]: 'Everything filed under this tag.',
  [TYPE.address]: 'What this address has kept.',
}

export function ItemDetail() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const say = useSay()
  const [forgetting, setForgetting] = useState(false)
  const [asking, setAsking] = useState(false)
  const [notingOpen, setNotingOpen] = useState(false)
  const [taggerOpen, setTaggerOpen] = useState(false)
  const [zoomed, setZoomed] = useState<{ url: string; alt: string } | null>(
    null,
  )
  const { data, loading, error, refetch } = useQuery(FeedDetailDocument, { id })
  const analyze = useAloud(
    AnalyzeFeedDocument,
    'That item could not be analyzed.',
  )
  const split = useAloud(
    SplitReferenceDocument,
    'That place could not be kept apart.',
  )
  const forget = useAloud(
    ForgetFeedDocument,
    'That item could not be forgotten.',
  )
  const rename = useAloud(RenameFeedDocument, 'That name could not be kept.')
  const note = useAloud(NoteFeedDocument, 'That note could not be kept.')
  const untagging = useAloud(TagFeedsDocument, 'That tag could not be removed.')
  const lifetime = useAloud(
    SetFeedLifetimeDocument,
    'That could not be kept for good.',
  )
  const settled = useCallback(() => refetch(), [refetch])

  const item = data?.feed

  useTitle(item?.title ?? item?.key ?? 'Item')

  if (loading && !data) return <Loader size="sm" color="var(--accent)" />
  if (error) return <Alert color="red">{error.message}</Alert>

  if (!item) return <Text c="dimmed">No such item.</Text>

  const facet = FACETS.has(item.type)
  const originals = item.references.filter(
    (reference) => reference.role === 'original',
  )
  const viewable = originals.filter((reference) => reference.thumbnailUrl)
  const waveforms = viewable.filter((reference) =>
    reference.contentType?.startsWith('audio/'),
  )
  const pictured = viewable.filter(
    (reference) => !reference.contentType?.startsWith('audio/'),
  )
  const filed = [...item.mimes, ...item.tags]

  const untag = async (key: string) => {
    const answered = await untagging.execute({
      ids: [item.id],
      tag: key,
      tagged: false,
    })

    if (!answered?.tagFeeds) return

    say({ text: `Removed ${key}.` })
    refetch()
  }
  const drawnOn = new Set(
    item.analyses.flatMap((pass) => pass.drewOn.map((held) => held.id)),
  )
  const placement = placementOf(item.analyses)
  const name = item.title ?? item.key

  return (
    <Stack gap="var(--s5)">
      <Link to="/" className="back">
        <IconArrowLeft size={15} stroke={1.8} />
        Catalog
      </Link>

      <header className="item-head" style={toned(lookOf(item).tone)}>
        <div className="item-lead">
          {facet && <Thumb looked={item} alt="" size={56} />}
          {!facet && pictured.length > 0 && (
            <button
              type="button"
              className="thumb-open thumb-header"
              onClick={() =>
                setZoomed({
                  url: pictured[0].hiresUrl ?? pictured[0].contentUrl,
                  alt: pictured[0].filename,
                })
              }
            >
              <img
                src={pictured[0].thumbnailUrl ?? undefined}
                alt={pictured[0].filename}
                loading="lazy"
                className="thumb-header-image"
              />
            </button>
          )}
          <div className="item-copy">
            {facet ? (
              <h1 className="page-title mono-title">{item.key}</h1>
            ) : (
              <Naming
                title={name}
                busy={rename.loading}
                onName={async (next) => {
                  const answered = await rename.execute({
                    id: item.id,
                    title: next,
                  })

                  if (!answered) return false

                  refetch()
                  return true
                }}
              />
            )}
            <div className="item-meta">
              <TypeBadge type={item.type} mime={item.mime} />
              <span className="eyebrow">
                {standing(
                  item,
                  originals.length,
                  originals.filter((reference) => reference.goneAt).length,
                )}
              </span>
              {item.expiresAt && (
                <>
                  <span
                    className="tag"
                    style={{ '--tone': 'var(--busy)' } as CSSProperties}
                    title="Kept by an agent while answering a question, and forgotten on this day unless you keep it"
                  >
                    forgotten {new Date(item.expiresAt).toLocaleDateString()}
                  </span>
                  <Button
                    size="compact-xs"
                    radius="xl"
                    variant="subtle"
                    color="gray"
                    loading={lifetime.loading}
                    onClick={async () => {
                      const answered = await lifetime.execute({
                        id: item.id,
                        lasts: 'forever',
                      })

                      if (!answered) return

                      say({ text: `${name} is kept for good.` })
                      refetch()
                    }}
                  >
                    Keep forever
                  </Button>
                </>
              )}
            </div>
          </div>
        </div>

        {!facet && (
          <div className="item-actions">
            {!item.asked && (
              <Button
                radius="xl"
                color="brand"
                className="item-ask"
                leftSection={<IconSparkles size={16} />}
                aria-expanded={asking}
                onClick={() => setAsking((held) => !held)}
              >
                Ask about this
              </Button>
            )}

            <Menu position="bottom-end" width={200}>
              <Menu.Target>
                <Button
                  radius="xl"
                  variant="default"
                  px="var(--s3)"
                  aria-label={`More for ${name}`}
                >
                  <IconDots size={16} stroke={1.8} />
                </Button>
              </Menu.Target>
              <Menu.Dropdown>
                <Menu.Item
                  leftSection={<IconNote size={15} stroke={1.6} />}
                  onClick={() => setNotingOpen(true)}
                >
                  Add a note
                </Menu.Item>
                <Menu.Item
                  leftSection={<IconTag size={15} stroke={1.6} />}
                  onClick={() => setTaggerOpen(true)}
                >
                  Tag
                </Menu.Item>
                <Menu.Item
                  leftSection={<IconRefresh size={15} stroke={1.6} />}
                  disabled={analyze.loading}
                  onClick={async () => {
                    const answered = await analyze.execute({ id: item.id })

                    if (!answered) return

                    say({
                      text: item.asked
                        ? 'Asking again.'
                        : `Analyzing ${name} again.`,
                    })
                    refetch()
                  }}
                >
                  {item.asked ? 'Ask again' : 'Re-analyze'}
                </Menu.Item>
                <Menu.Divider />
                <Menu.Item
                  color="red"
                  leftSection={<IconEraser size={15} stroke={1.6} />}
                  onClick={() => setForgetting(true)}
                >
                  Forget
                </Menu.Item>
              </Menu.Dropdown>
            </Menu>
          </div>
        )}
      </header>

      {asking && (
        <AskAboutThis
          id={item.id}
          name={name}
          onClose={() => setAsking(false)}
        />
      )}

      <Sure
        opened={forgetting}
        onClose={() => setForgetting(false)}
        title={`Forget ${name}?`}
        verb="Forget it"
        loading={forget.loading}
        onSure={async () => {
          const answered = await forget.execute({ id: item.id })

          if (!answered) return

          setForgetting(false)
          say({ text: `${name} is out of the catalog.` })
          navigate('/')
        }}
      >
        xixo stops pointing at the{' '}
        <strong>
          {originals.length} {originals.length === 1 ? 'place' : 'places'}
        </strong>{' '}
        it lives and drops it from search. Not one of those places is touched —
        the files stay exactly where they are, and a later sync of the same
        resource will catalogue this again.
      </Sure>

      {item.parent && (
        <Text size="sm" c="dimmed">
          Extracted from{' '}
          <Link to={hrefFor(item.parent)} className="inline-link">
            {item.parent.title ?? item.parent.key}
          </Link>
        </Text>
      )}

      {waveforms.map((reference) => (
        <a
          key={reference.id}
          href={reference.contentUrl}
          target="_blank"
          rel="noreferrer"
          style={{ display: 'block' }}
        >
          <img
            src={reference.thumbnailUrl ?? undefined}
            alt={reference.filename}
            loading="lazy"
            className="thumb-wave"
          />
        </a>
      ))}

      <Modal
        opened={zoomed !== null}
        onClose={() => setZoomed(null)}
        size="auto"
        centered
      >
        {zoomed && (
          <Stack gap="var(--s3)" align="center">
            <img src={zoomed.url} alt={zoomed.alt} className="zoomed-image" />
            <a
              href={zoomed.url}
              target="_blank"
              rel="noreferrer"
              className="inline-link"
            >
              Open full size
            </a>
          </Stack>
        )}
      </Modal>

      {filed.length > 0 && (
        <OneLine className="filed" noun="tags">
          {filed.map((held) => (
            <span key={held.id} className="filed-tag">
              <Link
                to={hrefFor(held)}
                className="tag"
                style={toned(lookOf(held).tone)}
              >
                {held.key}
              </Link>
              {held.type === TYPE.tag && !facet && (
                <button
                  type="button"
                  className="filed-untag"
                  aria-label={`Remove the tag ${held.key}`}
                  disabled={untagging.loading}
                  onClick={() => untag(held.key)}
                >
                  <IconX size={12} stroke={2} />
                </button>
              )}
            </span>
          ))}
        </OneLine>
      )}

      {!facet &&
        (taggerOpen || filed.some((held) => held.type === TYPE.tag)) && (
          <Tagger ids={[item.id]} onTagged={settled} />
        )}

      {!facet && (
        <Noting
          note={item.note ?? ''}
          busy={note.loading}
          open={notingOpen}
          onOpenChange={setNotingOpen}
          onNote={async (next) => {
            const answered = await note.execute({ id: item.id, note: next })

            if (!answered) return false

            say({ text: next ? 'Noted.' : 'The note is gone.' })
            refetch()
            return true
          }}
        />
      )}

      {item.asked && <Conversation feedId={item.id} onChanged={settled} />}

      {!facet && !item.asked && item.summary && (
        <p className="item-summary">{item.summary}</p>
      )}

      {item.children.length > 0 && (
        <Stack gap="var(--s3)">
          <div className="label">Contents</div>
          <Rows rows={item.children} />
        </Stack>
      )}

      <Connections
        key={`${item.id}-${item.connectedCount}`}
        id={item.id}
        hidden={drawnOn}
        facet={facet}
        about={ABOUT[item.type]}
      />

      {!facet && !item.asked && item.details.length > 0 && (
        <Section label="Details">
          <Readout details={item.details} />
        </Section>
      )}

      {(originals.length > 0 || item.staged) && (
        <Section label="Storage" defaultOpen={item.staged}>
          <div className="panel">
            {item.staged && (
              <div
                className="entry"
                data-spine="true"
                style={toned('var(--accent)')}
              >
                <div style={{ minWidth: 0 }}>
                  <span className="entry-title">Not stored yet</span>
                  <Text size="xs" c="dimmed" mt="var(--s1)">
                    It is held while the pass reads it and decides which of your
                    places it belongs in.
                  </Text>
                </div>
              </div>
            )}

            {originals.map((reference) => (
              <div
                key={reference.id}
                className="entry"
                data-spine="true"
                style={toned('var(--edge)')}
              >
                <div style={{ minWidth: 0 }}>
                  <Group gap="var(--s2)">
                    <span className="entry-title">
                      {reference.resource.key}
                    </span>
                    <span className="tag" data-dot="false">
                      {reference.resource.type}
                    </span>
                  </Group>

                  <Text
                    size="xs"
                    mt="var(--s2)"
                    className="mono"
                    style={{ color: 'var(--soft)', wordBreak: 'break-all' }}
                  >
                    {reference.locatorKey ?? '—'}
                  </Text>

                  <Text size="xs" c="dimmed" mt="var(--s1)">
                    {reference.contentType}
                    {reference.analyzedAt
                      ? ` · analyzed ${new Date(reference.analyzedAt).toLocaleString()}`
                      : ' · not analyzed'}
                    {reference.digest &&
                      originals.some(
                        (other) =>
                          other.id !== reference.id &&
                          other.digest === reference.digest,
                      ) &&
                      ' · the same bytes as another place'}
                  </Text>

                  {placement &&
                    placement.resource === reference.resource.key &&
                    placement.path === reference.locatorKey && (
                      <Text size="xs" mt="var(--s1)" className="placed">
                        {why(placement)}
                      </Text>
                    )}
                </div>

                <Group gap="var(--s2)" wrap="nowrap">
                  <Button
                    component="a"
                    href={reference.contentUrl}
                    target="_blank"
                    rel="noreferrer"
                    variant="default"
                    radius="xl"
                    size="xs"
                  >
                    Open
                  </Button>
                  <Button
                    component="a"
                    href={`${reference.contentUrl}?download=1`}
                    variant="default"
                    radius="xl"
                    size="xs"
                  >
                    Download
                  </Button>
                  {originals.length > 1 && (
                    <Button
                      variant="subtle"
                      color="gray"
                      radius="xl"
                      size="xs"
                      leftSection={<IconCut size={14} />}
                      onClick={async () => {
                        const answered = await split.execute({
                          id: reference.id,
                        })

                        if (!answered) return

                        say({
                          text: `${reference.resource.key} is its own item now, and stays apart until its bytes change.`,
                        })
                        refetch()
                      }}
                    >
                      Keep apart
                    </Button>
                  )}
                </Group>
              </div>
            ))}
          </div>
        </Section>
      )}

      {!facet && (
        <Section
          label="Analysis"
          defaultOpen={item.analyses.some((pass) => pass.status !== 'done')}
        >
          <Passes passes={item.analyses} onSettled={settled} />
        </Section>
      )}
    </Stack>
  )
}

function Section({
  label,
  defaultOpen = false,
  children,
}: {
  label: string
  defaultOpen?: boolean
  children: ReactNode
}) {
  const [open, setOpen] = useState(defaultOpen)

  return (
    <section className="fold" data-open={open}>
      <button
        type="button"
        className="fold-head"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span className="label">{label}</span>
        <IconChevronDown size={16} stroke={1.8} className="fold-chevron" />
      </button>
      {open && <div className="fold-body">{children}</div>}
    </section>
  )
}

function standing(
  item: {
    type: string
    analyzedAt?: string | null
    connectedCount: number
    staged: boolean
  },
  places: number,
  gone = 0,
) {
  if (FACETS.has(item.type)) {
    return `${item.connectedCount} filed under it`
  }

  const where = item.staged
    ? 'waiting for somewhere to live'
    : item.type === TYPE.note && places === 0
      ? null
      : gone > 0 && gone === places
        ? 'no longer found where it lived'
        : gone > 0
          ? `${places - gone} ${places - gone === 1 ? 'place' : 'places'} it lives, ${gone} where it is no longer found`
          : `${places} ${places === 1 ? 'place' : 'places'} it lives`
  const when = item.analyzedAt
    ? `analyzed ${new Date(item.analyzedAt).toLocaleString()}`
    : 'never analyzed'

  return where ? `${where} · ${when}` : when
}

function breakable(title: string) {
  let offset = 0

  return title.split(/(?<=[_./-])/).map((part) => {
    const at = offset
    offset += part.length

    return at === 0 ? (
      part
    ) : (
      <Fragment key={at}>
        <wbr />
        {part}
      </Fragment>
    )
  })
}

function Naming({
  title,
  busy,
  onName,
}: {
  title: string
  busy: boolean
  onName: (next: string) => Promise<boolean>
}) {
  const [naming, setNaming] = useState(false)
  const [draft, setDraft] = useState(title)
  const box = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    if (naming) box.current?.select()
  }, [naming])

  const keep = async () => {
    if (draft.trim() === title.trim()) return setNaming(false)
    if (await onName(draft)) setNaming(false)
  }

  if (!naming) {
    return (
      <button
        type="button"
        className="naming"
        title={title ? `Rename ${title}` : 'Rename'}
        onClick={() => {
          setDraft(title)
          setNaming(true)
        }}
      >
        <h1 className="page-title page-title-line">
          {title ? breakable(title) : 'Untitled'}
        </h1>
        <IconPencil size={17} stroke={1.7} />
      </button>
    )
  }

  return (
    <input
      ref={box}
      className="naming-box"
      value={draft}
      disabled={busy}
      aria-label="Name"
      onChange={(event) => setDraft(event.currentTarget.value)}
      onBlur={keep}
      onKeyDown={(event) => {
        if (event.key === 'Enter') keep()
        if (event.key === 'Escape') setNaming(false)
      }}
    />
  )
}

function Noting({
  note,
  busy,
  open,
  onOpenChange,
  onNote,
}: {
  note: string
  busy: boolean
  open: boolean
  onOpenChange: (open: boolean) => void
  onNote: (next: string) => Promise<boolean>
}) {
  const [draft, setDraft] = useState(note)

  useEffect(() => setDraft(note), [note])

  const keep = async () => {
    if (await onNote(draft.trim())) onOpenChange(false)
  }

  if (!open) {
    if (!note) return null

    return (
      <Stack gap="var(--s2)">
        <Group justify="space-between" align="baseline">
          <div className="label">Your note</div>
          <Button
            size="compact-xs"
            variant="subtle"
            color="gray"
            onClick={() => onOpenChange(true)}
          >
            Edit
          </Button>
        </Group>

        <div className="panel note">{note}</div>
      </Stack>
    )
  }

  return (
    <Stack gap="var(--s2)">
      <div className="label">Your note</div>

      <Textarea
        autosize
        autoFocus
        minRows={3}
        value={draft}
        disabled={busy}
        aria-label="Your note"
        placeholder="Anything you want to remember about this — xixo will not touch it, and a search will find it."
        onChange={(event) => setDraft(event.currentTarget.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            setDraft(note)
            onOpenChange(false)
          }
        }}
      />

      <Group gap="var(--s2)">
        <Button
          size="xs"
          radius="xl"
          color="brand"
          loading={busy}
          onClick={keep}
        >
          Keep it
        </Button>
        <Button
          size="xs"
          radius="xl"
          variant="default"
          onClick={() => {
            setDraft(note)
            onOpenChange(false)
          }}
        >
          Cancel
        </Button>
      </Group>
    </Stack>
  )
}

function AskAboutThis({
  id,
  name,
  onClose,
}: {
  id: string
  name: string
  onClose: () => void
}) {
  const navigate = useNavigate()
  const ask = useAloud(AskCatalogDocument, 'That could not be asked.')
  const [question, setQuestion] = useState('')
  const box = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    box.current?.focus()
  }, [])

  const submit = async () => {
    const text = question.trim()
    if (!text || ask.loading) return

    const answered = await ask.execute({ question: text, aboutId: id })
    const held = answered?.askCatalog

    if (held) navigate(`/items/${held.feed.id}`)
  }

  return (
    <form
      className="ask-bar"
      onSubmit={(event) => {
        event.preventDefault()
        submit()
      }}
    >
      <IconSparkles size={17} stroke={1.7} color="var(--accent)" />
      <input
        value={question}
        onChange={(event) => setQuestion(event.currentTarget.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') onClose()
        }}
        placeholder={`Ask about ${name}`}
        aria-label={`Ask a question about ${name}`}
        maxLength={500}
        ref={box}
      />
      <Button
        type="submit"
        radius="xl"
        color="brand"
        size="compact-md"
        loading={ask.loading}
        disabled={!question.trim()}
        rightSection={<IconArrowRight size={15} />}
      >
        Ask
      </Button>
    </form>
  )
}
