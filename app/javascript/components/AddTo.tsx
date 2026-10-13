import { Button, Modal } from '@mantine/core'
import { IconChevronRight, IconCpu, IconFolder } from '@tabler/icons-react'
import { type CSSProperties, useState } from 'react'
import { AttachResourceDocument } from 'xixo'
import { useMutation } from 'xixo/react'
import { unraised } from '../shared'
import { GROUPS } from './Attach'
import { useSay } from './Say'

export interface Place {
  id: string | null
  key: string
  name: string
  host: string
  local: boolean
  folders: string[]
  services: Service[]
}

export interface Service {
  kind: string
  port: number
  localOnly?: boolean
  url?: string | null
  via?: string | null
}

export interface Held {
  type: string
  key: string
  machineId?: string | null
  settings: Record<string, unknown>
}

export interface Form {
  type?: string
  via?: string | null
  key?: string
  settings?: Record<string, string>
  shelf?: string | null
}

export const SERVERS: Record<string, string> = {
  ollama: 'Ollama',
  lmstudio: 'LM Studio',
}

function slug(text: string) {
  return (
    text
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'folder'
  )
}

function port(url: unknown) {
  try {
    return Number(new URL(`${url}`).port) || null
  } catch {
    return null
  }
}

export function unadded(place: Place, held: Held[]) {
  const taken = new Set(
    held
      .filter(
        (resource) =>
          resource.type === 'filesystem' && resource.machineId === place.id,
      )
      .map((resource) => `${resource.settings.folder ?? ''}`),
  )

  return place.folders.filter((folder) => !taken.has(folder))
}

export function addedAs(place: Place, service: Service, held: Held[]) {
  return held.find(
    (resource) =>
      resource.type === 'openai-compatible' &&
      resource.machineId === place.id &&
      port(resource.settings.base_url) === service.port,
  )
}

export interface Quick {
  kind: string
  url: string
  via?: string | null
  key: string
  name: string
}

export function quickFor(place: Place, service: Service): Quick | null {
  if (!service.url) return null

  const label = SERVERS[service.kind] ?? service.kind

  return {
    kind: service.kind,
    url: service.url,
    via: service.via ?? null,
    key: place.local ? service.kind : `${service.kind}-${place.key}`,
    name: place.local ? label : `${label} on ${place.name}`,
  }
}

export function useQuickAdd(administrator: boolean, onAdded: () => void) {
  const say = useSay()
  const attach = useMutation(AttachResourceDocument)
  const [busy, setBusy] = useState<string | null>(null)

  const add = async (quick: Quick) => {
    setBusy(quick.key)

    const { data, error } = await attach.attempt({
      type: 'openai-compatible',
      key: quick.key,
      name: quick.name,
      personal: !administrator,
      settings: { base_url: quick.url },
      via: quick.via ?? null,
    })

    setBusy(null)

    if (!data?.attachResource?.resource) {
      say({
        text: error?.message ?? `${quick.name} could not be added.`,
        wrong: true,
      })
      return false
    }

    onAdded()
    say(
      data.attachResource.checkError
        ? {
            text: `${quick.key} is added, but it did not answer: ${unraised(data.attachResource.checkError)}`,
            wrong: true,
          }
        : {
            text: `${quick.key} is added. Name a model for each role in Change.`,
          },
    )
    return true
  }

  return { add, busy }
}

export function AddTo({
  places,
  start,
  choosing,
  held,
  administrator,
  onForm,
  onAdded,
  onClose,
}: {
  places: Place[]
  start: Place
  choosing: boolean
  held: Held[]
  administrator: boolean
  onForm: (form: Form) => void
  onAdded: () => void
  onClose: () => void
}) {
  const [chosen, setChosen] = useState(start.key)
  const quickly = useQuickAdd(administrator, onAdded)
  const place = places.find((held) => held.key === chosen) ?? start
  const folders = unadded(place, held)
  const via = place.id ? place.key : null

  const quick = async (service: Service) => {
    const asked = quickFor(place, service)
    if (asked && (await quickly.add(asked))) onClose()
  }

  return (
    <Modal
      opened
      onClose={onClose}
      title={choosing ? 'Add a resource' : `Add to ${place.name}`}
      size="lg"
      padding="var(--s5)"
    >
      <div className="addto">
        {choosing && places.length > 1 && (
          <div className="addto-places">
            {places.map((held) => (
              <button
                key={held.key}
                type="button"
                aria-pressed={held.key === place.key}
                className="chip"
                data-on={held.key === place.key}
                onClick={() => setChosen(held.key)}
              >
                {held.name}
              </button>
            ))}
          </div>
        )}

        {administrator && place.id && (
          <section className="addto-part">
            <h3 className="label addto-label">Folders it shares</h3>
            {folders.length > 0 ? (
              <ul className="addto-list">
                {folders.map((folder) => (
                  <li key={folder}>
                    <button
                      type="button"
                      className="addto-item"
                      onClick={() =>
                        onForm({
                          type: 'filesystem',
                          via,
                          key: slug(folder.split('/').pop() ?? folder),
                          settings: { folder },
                        })
                      }
                    >
                      <IconFolder size={18} stroke={1.7} />
                      <span className="addto-item-name mono">{folder}</span>
                      <IconChevronRight size={16} stroke={1.8} />
                    </button>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="addto-quiet">
                {place.folders.length > 0
                  ? 'Every folder it shares is added.'
                  : `${place.name} shares no folders yet. The config of xixo link on it lists them.`}
              </p>
            )}
          </section>
        )}

        {place.services.length > 0 && (
          <section className="addto-part">
            <h3 className="label addto-label">Model servers it found</h3>
            <ul className="addto-list">
              {place.services.map((service) => {
                const label = SERVERS[service.kind] ?? service.kind
                const added = addedAs(place, service, held)

                return (
                  <li key={`${service.kind}-${service.port}`}>
                    <div className="addto-item" data-static="true">
                      <IconCpu size={18} stroke={1.7} />
                      <span className="addto-item-name">
                        {label}
                        <span className="addto-item-says">
                          {added
                            ? `added as ${added.key}`
                            : service.via
                              ? `port ${service.port}, through ${service.via}`
                              : `port ${service.port}`}
                        </span>
                      </span>
                      {added ? null : service.url ? (
                        <Button
                          size="compact-sm"
                          radius="xl"
                          color="brand"
                          loading={
                            quickly.busy === quickFor(place, service)?.key
                          }
                          onClick={() => quick(service)}
                        >
                          Add
                        </Button>
                      ) : (
                        <Button
                          size="compact-sm"
                          radius="xl"
                          variant="default"
                          onClick={() =>
                            onForm({
                              type: 'openai-compatible',
                              key: place.local
                                ? service.kind
                                : `${service.kind}-${place.key}`,
                              settings: {
                                base_url: `http://${place.host}:${service.port}/v1`,
                              },
                            })
                          }
                        >
                          Set up
                        </Button>
                      )}
                    </div>
                  </li>
                )
              })}
            </ul>
          </section>
        )}

        {place.local && (
          <section className="addto-part">
            <h3 className="label addto-label">Reached from here</h3>
            <div className="addto-kinds">
              {GROUPS.map((group) => (
                <button
                  key={group.short}
                  type="button"
                  className="addto-kind"
                  style={{ '--tone': group.tone } as CSSProperties}
                  onClick={() => onForm({ shelf: group.short })}
                >
                  <span className="attach-dot" />
                  {group.title}
                </button>
              ))}
              <button
                type="button"
                className="addto-kind"
                style={{ '--tone': 'var(--k-file)' } as CSSProperties}
                onClick={() => onForm({ shelf: null })}
              >
                <span className="attach-dot" />
                Everything
              </button>
            </div>
          </section>
        )}

        {!place.local && !administrator && (
          <p className="addto-quiet">
            An administrator adds what lives on {place.name}.
          </p>
        )}
      </div>
    </Modal>
  )
}
