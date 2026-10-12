import { createConsumer } from '@rails/actioncable'
import { type Exchange, subscriptionExchange } from '@urql/core'
import type { GraphQLFormattedError } from 'graphql'

interface SubscriptionPayload {
  result?: {
    data?: Record<string, unknown> | null
    errors?: GraphQLFormattedError[]
  }
  more: boolean
}

function answered(result: SubscriptionPayload['result']) {
  if (!result) return false
  if (result.errors?.length) return true

  return Object.keys(result.data ?? {}).length > 0
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
                if (answered(payload.result)) {
                  sink.next({
                    data: payload.result?.data ?? undefined,
                    errors: payload.result?.errors,
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
