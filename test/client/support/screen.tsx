import { MantineProvider } from '@mantine/core'
import { render } from '@testing-library/react'
import { CombinedError } from '@urql/core'
import { getOperationAST } from 'graphql'
import type { ReactNode } from 'react'
import { MemoryRouter } from 'react-router-dom'
import type { XixoClient } from 'xixo'
import { XixoProvider } from 'xixo/react'
import { SayProvider } from '../../../app/javascript/components/Say'
import { theme } from '../../../app/javascript/theme'

type Variables = Record<string, unknown>
type Answer = (variables: Variables) => unknown

interface Asked {
  name: string
  variables: Variables
}

export function page(nodes: unknown[]) {
  return { nodes, hasMore: false, nextCursor: null, total: nodes.length }
}

export function fakeClient(answers: Record<string, Answer>) {
  const asked: Asked[] = []

  const answer = (
    document: Parameters<typeof getOperationAST>[0],
    variables: Variables = {},
  ) => {
    const name = getOperationAST(document)?.name?.value ?? ''
    const given = answers[name]

    asked.push({ name, variables })

    if (!given) throw new Error(`nothing answers ${name}`)

    try {
      return { data: given(variables), error: undefined }
    } catch (error) {
      return {
        data: undefined,
        error: new CombinedError({ networkError: error as Error }),
      }
    }
  }

  const ask = (document: never, variables: Variables) => ({
    toPromise: async () => answer(document, variables),
  })
  const client = {
    query: ask,
    mutation: ask,
    subscription: () => ({ subscribe: () => ({ unsubscribe() {} }) }),
  } as unknown as XixoClient

  return { client, asked }
}

export function show(ui: ReactNode, client: XixoClient, at = '/') {
  return render(
    <MantineProvider theme={theme} forceColorScheme="dark" env="test">
      <XixoProvider client={client}>
        <MemoryRouter initialEntries={[at]}>
          <SayProvider>{ui}</SayProvider>
        </MemoryRouter>
      </XixoProvider>
    </MantineProvider>,
  )
}
