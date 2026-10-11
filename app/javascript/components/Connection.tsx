import { IconPlugConnectedX, IconWifiOff } from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import { useConnection } from '../connection'

const GRACE = 4000

export function Connection() {
  const state = useConnection()
  const [shown, setShown] = useState(state)

  useEffect(() => {
    if (state !== 'dropped') {
      setShown(state)
      return
    }

    const timer = setTimeout(() => setShown(state), GRACE)
    return () => clearTimeout(timer)
  }, [state])

  if (shown === 'live') return null

  return (
    <div className="connection" role="status">
      {shown === 'offline' ? (
        <>
          <IconWifiOff size={15} stroke={1.8} />
          This device is offline. What is on screen stays, and nothing new
          arrives until it is back.
        </>
      ) : (
        <>
          <IconPlugConnectedX size={15} stroke={1.8} />
          Live updates stopped. xixo is reconnecting.
        </>
      )}
    </div>
  )
}
