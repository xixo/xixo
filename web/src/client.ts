import {
  Client,
  cacheExchange,
  type Exchange,
  fetchExchange,
  mapExchange,
} from '@urql/core'

export interface XixoOptions {
  url: string
  csrfToken?: () => string | null
  onUnauthorized?: () => void
  subscriptions?: Exchange
}

export type XixoClient = Client

export function createXixo(options: XixoOptions): XixoClient {
  const { url, csrfToken, onUnauthorized, subscriptions } = options

  return new Client({
    url,
    exchanges: [
      cacheExchange,
      mapExchange({
        onError(error) {
          if (error.response?.status === 401) onUnauthorized?.()
        },
      }),
      fetchExchange,
      ...(subscriptions ? [subscriptions] : []),
    ],
    fetchOptions: () => ({
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken?.() ?? '',
      },
    }),
  })
}

export function metaCSRFToken(): string | null {
  const meta = document.querySelector('meta[name="csrf-token"]')
  return meta?.getAttribute('content') ?? null
}
