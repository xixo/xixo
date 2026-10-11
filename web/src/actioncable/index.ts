import { createConsumer } from '@rails/actioncable'
import { type Exchange, subscriptionExchange } from '@urql/core'

interface SubscriptionPayload {
  result: Record<string, unknown>
  more: boolean
}

export interface ActionCableOptions {
  channel?: string
  url?: string
  onConnection?: (open: boolean) => void
}

export function actionCableExchange(
  options: ActionCableOptions = {},
): Exchange {
  const { channel = 'GraphqlChannel', url, onConnection } = options
  const cable = url ? createConsumer(url) : createConsumer()
  let open: boolean | null = null
  const told = (now: boolean) => {
    if (now === open) return

    open = now
    onConnection?.(now)
  }

  return subscriptionExchange({
    forwardSubscription(request) {
      return {
        subscribe(sink) {
          const subscription = cable.subscriptions.create(
            { channel },
            {
              connected() {
                told(true)
                subscription.perform('execute', {
                  query: request.query,
                  variables: request.variables,
                  operationName: request.operationName,
                })
              },
              disconnected() {
                told(false)
              },
              received(payload: SubscriptionPayload) {
                if (payload.result) {
                  sink.next({
                    data: payload.result.data as Record<string, unknown>,
                  })
                }
                if (!payload.more) {
                  sink.complete()
                }
              },
            },
          )

          return {
            unsubscribe: () => subscription.unsubscribe(),
          }
        },
      }
    },
  })
}
