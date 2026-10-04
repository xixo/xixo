import { createXixo, metaCSRFToken } from '@xixo/client'
import { actionCableExchange } from '@xixo/client/actioncable'
import { session } from './hooks/useSession'

export const client = createXixo({
  url: '/graphql',
  csrfToken: metaCSRFToken,
  onUnauthorized: () => session.login(),
  subscriptions: actionCableExchange(),
})
