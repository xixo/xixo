import { Modal } from '@mantine/core'
import { IconCpu } from '@tabler/icons-react'
import { type CSSProperties, useState } from 'react'
import { GROUPS } from './Attach'

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

function port(url: unknown) {
  try {
    return Number(new URL(`${url}`).port) || null
  } catch {
    return null
  }
}

export function addedAs(place: Place, service: Service, held: Held[]) {
  return held.find(
    (resource) =>
      resource.type === 'openai-compatible' &&
      resource.machineId === place.id &&
      port(resource.settings.base_url) === service.port,
  )
}

export function AddTo({
  places,
  start,
  choosing,
  held,
  administrator,
  onForm,
  onClose,
}: {
  places: Place[]
  start: Place
  choosing: boolean
  held: Held[]
  administrator: boolean
  onForm: (form: Form) => void
  onClose: () => void
}) {
  const [chosen, setChosen] = useState(start.key)
  const place = places.find((held) => held.key === chosen) ?? start

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

        {!place.local && (
          <p className="addto-quiet">
            {place.folders.length > 0
              ? `Every folder ${place.name} shares joins the catalog by itself.`
              : `${place.name} shares no folders yet. The link-up command names them.`}
            {place.services.length === 0 &&
              ` xixo found no model server on ${place.name}.`}
          </p>
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
                            : `port ${service.port}, added when the plan runs models`}
                        </span>
                      </span>
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
