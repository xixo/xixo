import { Loader } from '@mantine/core'
import {
  IconAlertTriangle,
  IconBrandApple,
  IconBrandDebian,
  IconBrandUbuntu,
  IconServer,
} from '@tabler/icons-react'
import { type ReactNode, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import {
  LinkRequestChangedDocument,
  LinkRequestDocument,
  MachineChangedDocument,
} from 'xixo'
import { useQuery, useSubscription } from 'xixo/react'
import { useTitle } from '../hooks/useTitle'
import { systemOf } from '../linkup'
import { sized } from '../plain'
import { ago } from '../when'
import { Failed } from './Failed'
import { Decide, type LinkRequest, nameOf } from './LinkUp'
import { administratorSignIn } from './Resources'

const SERVICES: Record<string, string> = {
  ollama: 'Ollama',
  lmstudio: 'LM Studio',
}

export function titleFor(request: LinkRequest | null) {
  if (!request) return 'Approve a machine'

  const name = nameOf(request)
  if (request.status === 'linked') return `${name} is linked up`
  if (request.status === 'denied') return `${name} was denied`

  return `Approve ${name}`
}

export function LinkApproval() {
  const { code = '' } = useParams()
  const { data, loading, error, refetch } = useQuery(LinkRequestDocument, {
    code,
  })
  const administrator = data?.administrator ?? false
  const request = (data?.linkRequest ?? null) as LinkRequest | null
  const changed = useSubscription(
    LinkRequestChangedDocument,
    {},
    { skip: !administrator },
  )
  const machines = useSubscription(
    MachineChangedDocument,
    {},
    { skip: !administrator },
  )

  useTitle(titleFor(request))

  useEffect(() => {
    if (changed.data || machines.data) refetch()
  }, [changed.data, machines.data, refetch])

  if (loading && !data) return <Loader size="sm" color="var(--accent)" />
  if (error) return <Failed error={error} retry={refetch} />

  return (
    <div className="settings-page linkup-approval">
      {!administrator ? (
        <>
          <Heading title={titleFor(null)} />
          <p className="quiet-note">
            <span>Only an administrator approves machines.</span>
            <a href={administratorSignIn()}>Sign in as one</a>
          </p>
        </>
      ) : request ? (
        <Approval request={request} onChanged={refetch} />
      ) : (
        <>
          <Heading title={titleFor(null)} />
          <p className="linkup-quiet">
            No machine is asking with that code. The request may have run out.
            Run the command on the machine again.
          </p>
        </>
      )}

      <p className="linkup-quiet">
        <Link to="/settings/resources">Go to Resources</Link>
      </p>
    </div>
  )
}

function Heading({
  title,
  icon,
  lead,
}: {
  title: string
  icon?: ReactNode
  lead?: string | null
}) {
  return (
    <header className="linkup-machine">
      {icon && <span className="linkup-machine-icon">{icon}</span>}
      <h1 className="settings-title">{title}</h1>
      {lead && <p className="linkup-machine-system">{lead}</p>}
    </header>
  )
}

function SystemIcon({ request }: { request: LinkRequest }) {
  const system = (request.system ?? '').toLowerCase()

  if (request.os === 'darwin') return <IconBrandApple size={44} stroke={1.5} />
  if (system.includes('ubuntu'))
    return <IconBrandUbuntu size={44} stroke={1.5} />
  if (system.includes('debian'))
    return <IconBrandDebian size={44} stroke={1.5} />

  return <IconServer size={44} stroke={1.5} />
}

function Approval({
  request,
  onChanged,
}: {
  request: LinkRequest
  onChanged: () => void
}) {
  const lead = [
    request.system ?? systemOf(request.os, null),
    request.model,
    request.arch,
  ]
    .filter(Boolean)
    .join(' · ')

  return (
    <>
      <Heading
        title={titleFor(request)}
        icon={<SystemIcon request={request} />}
        lead={lead}
      />

      <div className="linkup-request" data-status={request.status}>
        <Decide request={request} onChanged={onChanged} />
      </div>

      {request.status === 'pending' && request.namedLike && (
        <p className="linkup-notice">
          <IconAlertTriangle size={18} stroke={1.8} />
          <span>
            A machine named {request.namedLike} is already linked. Approving
            adds this one as a second machine, {request.linksAs}.
          </span>
        </p>
      )}

      <Details request={request} />
    </>
  )
}

function useNow(every = 30_000) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), every)
    return () => clearInterval(timer)
  }, [every])

  return now
}

function runsOut(expiresAt: string, now: number) {
  const minutes = Math.ceil((new Date(expiresAt).getTime() - now) / 60_000)
  if (minutes <= 0) return 'ran out'

  return `runs out in ${minutes} ${minutes === 1 ? 'minute' : 'minutes'}`
}

function Details({ request }: { request: LinkRequest }) {
  const now = useNow()
  const disks = request.disks ?? []
  const hardware = [
    request.cpus
      ? `${request.cpus} ${request.cpus === 1 ? 'core' : 'cores'}`
      : null,
    sized(request.memory) ? `${sized(request.memory)} memory` : null,
  ].filter(Boolean)
  const asked = [
    request.createdAt ? ago(request.createdAt) : null,
    request.status === 'pending' ? runsOut(request.expiresAt, now) : null,
  ].filter(Boolean)

  return (
    <dl className="linkup-details">
      <Row label="Shares">
        {request.folders.length === 0 ? (
          'No folders'
        ) : (
          <ul className="linkup-folders">
            {request.folders.map((folder) => {
              const disk = disks.find((held) => held.path === folder)
              const free = sized(disk?.free)
              const total = sized(disk?.total)

              return (
                <li key={folder}>
                  <code>{folder}</code>
                  <span>
                    {request.writable.includes(folder)
                      ? 'Read and write'
                      : 'Read only'}
                    {free && total ? ` · ${free} free of ${total}` : ''}
                  </span>
                </li>
              )
            })}
          </ul>
        )}
      </Row>

      {request.user && <Row label="Runs as">{request.user}</Row>}
      {hardware.length > 0 && (
        <Row label="Hardware">{hardware.join(' · ')}</Row>
      )}
      {(request.addresses ?? []).length > 0 && (
        <Row label="Addresses">{(request.addresses ?? []).join(', ')}</Row>
      )}
      {request.remoteIp && (
        <Row label="Asked from">
          {request.remoteIp}
          {request.sameAddress != null && (
            <span
              className="linkup-details-hint"
              data-same={request.sameAddress}
            >
              {request.sameAddress
                ? 'Same address as this browser'
                : 'A different address than this browser'}
            </span>
          )}
        </Row>
      )}
      {(request.services ?? []).length > 0 && (
        <Row label="Found">
          {(request.services ?? [])
            .map(
              (service) =>
                `${SERVICES[service.kind] ?? service.kind} on port ${service.port}`,
            )
            .join(', ')}
        </Row>
      )}
      {request.version && <Row label="xixo link">{request.version}</Row>}
      {request.linksAs && <Row label="Links up as">{request.linksAs}</Row>}
      {asked.length > 0 && <Row label="Asked">{asked.join(' · ')}</Row>}
    </dl>
  )
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="linkup-details-row">
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  )
}
