import type { TypedDocumentNode } from '@graphql-typed-document-node/core'
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import type { XixoClient } from '../client.js'

const XixoContext = createContext<XixoClient | null>(null)

export function XixoProvider({
  client,
  children,
}: {
  client: XixoClient
  children: ReactNode
}) {
  return <XixoContext.Provider value={client}>{children}</XixoContext.Provider>
}

export function useXixo(): XixoClient {
  const client = useContext(XixoContext)
  if (!client) {
    throw new Error('useXixo must be used inside a XixoProvider')
  }
  return client
}

interface QueryOptions {
  skip?: boolean
}

export function useQuery<TData, TVariables extends Record<string, unknown>>(
  query: TypedDocumentNode<TData, TVariables>,
  variables?: TVariables,
  options?: QueryOptions,
) {
  const client = useXixo()
  const skip = options?.skip ?? false
  const [data, setData] = useState<TData | null>(null)
  const [loading, setLoading] = useState(!skip)
  const [error, setError] = useState<Error | null>(null)
  const variablesRef = useRef(variables)
  variablesRef.current = variables
  const latest = useRef(0)

  const variablesKey = JSON.stringify(variables)

  const refetch = useCallback(
    (_key?: string) => {
      latest.current += 1
      const asked = latest.current
      setLoading(true)
      client
        .query(query, variablesRef.current ?? ({} as TVariables), {
          preferGetMethod: false,
          requestPolicy: 'network-only',
        })
        .toPromise()
        .then((result) => {
          if (asked !== latest.current) return
          if (result.error) {
            setError(new Error(result.error.message))
          } else {
            setError(null)
            setData(result.data ?? null)
          }
          setLoading(false)
        })
    },
    [client, query],
  )

  useEffect(() => {
    if (!skip) {
      refetch(variablesKey)
    }
  }, [refetch, variablesKey, skip])

  return { data, loading, error, refetch }
}

interface SubscriptionOptions {
  skip?: boolean
}

export function useSubscription<
  TData,
  TVariables extends Record<string, unknown>,
>(
  subscription: TypedDocumentNode<TData, TVariables>,
  variables?: TVariables,
  options?: SubscriptionOptions,
) {
  const client = useXixo()
  const skip = options?.skip ?? false
  const [data, setData] = useState<TData | null>(null)
  const [error, setError] = useState<Error | null>(null)
  const variablesKey = JSON.stringify(variables ?? {})
  const stableVariables = useMemo(
    () => JSON.parse(variablesKey) as TVariables,
    [variablesKey],
  )

  useEffect(() => {
    if (skip) return

    const { unsubscribe } = client
      .subscription(subscription, stableVariables)
      .subscribe((result) => {
        if (result.error) {
          setError(new Error(result.error.message))
        } else if (result.data) {
          setData(result.data)
        }
      })

    return () => unsubscribe()
  }, [client, subscription, stableVariables, skip])

  return { data, error }
}

export function useMutation<TData, TVariables extends Record<string, unknown>>(
  mutation: TypedDocumentNode<TData, TVariables>,
) {
  const client = useXixo()
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<Error | null>(null)

  const attempt = useCallback(
    async (
      variables: TVariables,
    ): Promise<{ data: TData | null; error: Error | null }> => {
      setLoading(true)
      setError(null)
      try {
        const result = await client.mutation(mutation, variables).toPromise()
        if (result.error) {
          const refused = new Error(result.error.message)
          setError(refused)
          return { data: null, error: refused }
        }
        return { data: result.data ?? null, error: null }
      } finally {
        setLoading(false)
      }
    },
    [client, mutation],
  )

  const execute = useCallback(
    async (variables: TVariables) => (await attempt(variables)).data,
    [attempt],
  )

  return { execute, attempt, loading, error }
}
