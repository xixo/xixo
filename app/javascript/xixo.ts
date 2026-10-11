import { createXixo, metaCSRFToken } from 'xixo'
import { actionCableExchange } from 'xixo/actioncable'
import { cableChanged } from './connection'
import { session } from './hooks/useSession'

export const client = createXixo({
  url: '/graphql',
  csrfToken: metaCSRFToken,
  onUnauthorized: () => session.login(),
  subscriptions: actionCableExchange({ onConnection: cableChanged }),
})
