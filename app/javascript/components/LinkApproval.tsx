import { Loader } from '@mantine/core'
import { useEffect } from 'react'
import { Link, useParams } from 'react-router-dom'
import {
  LinkRequestChangedDocument,
  LinkRequestDocument,
  MachineChangedDocument,
} from 'xixo'
import { useQuery, useSubscription } from 'xixo/react'
import { useTitle } from '../hooks/useTitle'
import { Failed } from './Failed'
import { type LinkRequest, RequestCard } from './LinkUp'
import { administratorSignIn } from './Resources'
import { Intro } from './Settings'

export function LinkApproval() {
  useTitle('Approve a machine')

  const { code = '' } = useParams()
  const { data, loading, error, refetch } = useQuery(LinkRequestDocument, {
    code,
  })
  const administrator = data?.administrator ?? false
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

  useEffect(() => {
    if (changed.data || machines.data) refetch()
  }, [changed.data, machines.data, refetch])

  if (loading && !data) return <Loader size="sm" color="var(--accent)" />
  if (error) return <Failed error={error} retry={refetch} />

  const request = (data?.linkRequest ?? null) as LinkRequest | null

  return (
    <div className="settings-page linkup-approval">
      <Intro
        title="Approve a machine"
        lead={
          <>
            Approve it only if the machine shows <code>{code}</code>.
          </>
        }
      />

      {!administrator ? (
        <p className="quiet-note">
          <span>Only an administrator approves machines.</span>
          <a href={administratorSignIn()}>Sign in as one</a>
        </p>
      ) : request ? (
        <RequestCard request={request} onChanged={refetch} />
      ) : (
        <p className="linkup-quiet">
          No machine is asking with that code. The request may have run out. Run
          the command on the machine again.
        </p>
      )}

      <p className="linkup-quiet">
        <Link to="/settings/resources">Go to Resources</Link>
      </p>
    </div>
  )
}
