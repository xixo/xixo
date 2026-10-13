import {
  Button,
  CopyButton,
  Modal,
  SegmentedControl,
  TextInput,
} from '@mantine/core'
import { IconCircleCheck, IconPlus } from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import {
  ApproveLinkRequestDocument,
  DenyLinkRequestDocument,
  LinkRequestChangedDocument,
  LinkRequestsDocument,
  MachineChangedDocument,
} from 'xixo'
import { useMutation, useQuery, useSubscription } from 'xixo/react'
import {
  command,
  detected,
  FOLDERS,
  folderList,
  SYSTEMS,
  systemOf,
} from '../linkup'

export interface LinkUpInfo {
  xixo: string
  systems: string[]
}

export interface LinkRequest {
  id: string
  code: string
  status: string
  hostname: string
  os?: string | null
  arch?: string | null
  folders: string[]
  writable: string[]
  remoteIp?: string | null
  expiresAt: string
  machine?: {
    id: string
    key: string
    machine?: { connected: boolean } | null
  } | null
}

function plural(count: number, one: string, many = `${one}s`) {
  return `${count} ${count === 1 ? one : many}`
}

export function LinkUpTile({ onLinkUp }: { onLinkUp: () => void }) {
  return (
    <button type="button" className="linkup-tile" onClick={onLinkUp}>
      <IconPlus size={22} stroke={1.8} />
      <span className="linkup-tile-name">Link up a machine</span>
    </button>
  )
}

export function useLinkRequests(skip = false) {
  const { data, refetch } = useQuery(LinkRequestsDocument, {}, { skip })
  const changed = useSubscription(LinkRequestChangedDocument, {}, { skip })
  const machines = useSubscription(MachineChangedDocument, {}, { skip })

  useEffect(() => {
    if (changed.data || machines.data) refetch()
  }, [changed.data, machines.data, refetch])

  return {
    requests: (data?.linkRequests ?? []) as LinkRequest[],
    refetch,
  }
}

export function LinkUpDialog({
  info,
  requests,
  onClose,
  onChanged,
}: {
  info: LinkUpInfo
  requests: LinkRequest[]
  onClose: () => void
  onChanged: () => void
}) {
  const [system, setSystem] = useState(() =>
    detected(info.systems, navigator.userAgent),
  )
  const [folders, setFolders] = useState<string[] | null>(null)
  const [editing, setEditing] = useState(false)
  const shared = folders ?? FOLDERS[system] ?? []
  const line = command(info.xixo, shared)
  const offered = info.systems.filter((held) => held in SYSTEMS)

  return (
    <Modal
      opened
      onClose={onClose}
      title="Link up a machine"
      size="lg"
      padding="var(--s5)"
    >
      <div className="linkup">
        <p className="linkup-lead">
          Run this on the machine, then approve it here.
        </p>

        {offered.length > 1 && (
          <SegmentedControl
            size="xs"
            className="linkup-system"
            value={system}
            onChange={(next) => {
              setSystem(next)
              setFolders(null)
              setEditing(false)
            }}
            data={offered.map((held) => ({
              value: held,
              label: SYSTEMS[held],
            }))}
          />
        )}

        {offered.length === 0 ? (
          <p className="linkup-quiet">
            This server holds no xixo link to hand out. The server image puts
            the builds in the folder XIXO_LINK_DIR names.
          </p>
        ) : (
          <div className="linkup-line">
            <code>{line}</code>
            <CopyButton value={line}>
              {({ copied, copy }) => (
                <Button
                  size="compact-sm"
                  radius="xl"
                  color="brand"
                  onClick={copy}
                >
                  {copied ? 'Copied' : 'Copy'}
                </Button>
              )}
            </CopyButton>
          </div>
        )}

        {offered.length > 0 &&
          (editing ? (
            <TextInput
              size="sm"
              label="Folders it shares"
              description="Separate them with spaces. End one with :rw to let xixo write into it."
              placeholder={system === 'darwin' ? '~/Documents' : '/srv/media'}
              spellCheck={false}
              autoFocus
              value={shared.join(' ')}
              onChange={(event) =>
                setFolders(folderList(event.currentTarget.value))
              }
              onBlur={() => setEditing(false)}
            />
          ) : (
            <p className="linkup-quiet">
              {shared.length > 0
                ? `Shares ${shared.join(', ')}.`
                : 'Shares no folders yet.'}{' '}
              <button
                type="button"
                className="linkup-change"
                onClick={() => setEditing(true)}
              >
                Change
              </button>
            </p>
          ))}

        <Requests requests={requests} onChanged={onChanged} />
      </div>
    </Modal>
  )
}

function Requests({
  requests,
  onChanged,
}: {
  requests: LinkRequest[]
  onChanged: () => void
}) {
  if (requests.length === 0)
    return (
      <div className="linkup-wait">
        <span className="linkup-dot" />
        Waiting for a machine to ask.
      </div>
    )

  return (
    <ul className="linkup-requests">
      {requests.map((request) => (
        <li key={request.id}>
          <RequestCard request={request} onChanged={onChanged} />
        </li>
      ))}
    </ul>
  )
}

export function RequestCard({
  request,
  onChanged,
}: {
  request: LinkRequest
  onChanged: () => void
}) {
  const approve = useMutation(ApproveLinkRequestDocument)
  const deny = useMutation(DenyLinkRequestDocument)
  const [refused, setRefused] = useState<string | null>(null)
  const linked = request.machine
  const connected = Boolean(linked?.machine?.connected)

  const decide = async (approving: boolean) => {
    setRefused(null)
    const { error } = approving
      ? await approve.attempt({ id: request.id })
      : await deny.attempt({ id: request.id })

    if (error) setRefused(error.message)
    onChanged()
  }

  const about = [
    systemOf(request.os, request.arch),
    request.folders.length > 0
      ? `shares ${request.folders.join(', ')}`
      : 'shares no folders',
    request.remoteIp ? `from ${request.remoteIp}` : null,
  ].filter(Boolean)

  return (
    <div className="linkup-request" data-status={request.status}>
      <div className="linkup-request-name">
        <strong>{linked?.key ?? request.hostname}</strong>
        <span>{about.join(' · ')}</span>
      </div>

      {request.status === 'pending' && (
        <>
          <div className="linkup-request-code">
            <span>It shows</span>
            <code>{request.code}</code>
          </div>
          <div className="linkup-request-acts">
            <Button
              size="compact-sm"
              radius="xl"
              variant="default"
              loading={deny.loading}
              onClick={() => decide(false)}
            >
              Deny
            </Button>
            <Button
              size="compact-sm"
              radius="xl"
              color="brand"
              loading={approve.loading}
              onClick={() => decide(true)}
            >
              Approve
            </Button>
          </div>
        </>
      )}

      {request.status !== 'pending' && (
        <div className="linkup-request-said">
          {request.status === 'denied' ? (
            'Denied.'
          ) : connected ? (
            <>
              <IconCircleCheck size={16} stroke={1.8} />
              Linked up.
            </>
          ) : linked ? (
            'Starting xixo link.'
          ) : (
            'Approved. Finishing on the machine.'
          )}
        </div>
      )}

      {refused && <div className="linkup-request-refused">{refused}</div>}
    </div>
  )
}

export function AskingLine({
  requests,
  onReview,
}: {
  requests: LinkRequest[]
  onReview: () => void
}) {
  const asking = requests.filter((request) => request.status === 'pending')
  if (asking.length === 0) return null

  const named =
    asking.length === 1
      ? `${asking[0].hostname} is asking to link up.`
      : `${plural(asking.length, 'machine')} are asking to link up.`

  return (
    <p className="linkup-asking">
      <span className="linkup-dot" />
      <span>{named}</span>
      <button type="button" onClick={onReview}>
        Review
      </button>
    </p>
  )
}
