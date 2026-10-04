# @xixo/client

A GraphQL and Action Cable client for [xixo](https://xixo.pages.dev), an indexer for personal data.
It is built on [urql](https://github.com/urql-graphql/urql) and ships typed documents for every
operation the xixo browser app uses.

## Installation

```sh
npm install @xixo/client
```

`graphql` is a required peer dependency. `react` and `@rails/actioncable` are optional peer
dependencies. Install them only if you import `@xixo/client/react` or
`@xixo/client/actioncable`.

## Usage

`createXixo` returns a urql `Client` that posts JSON to the GraphQL endpoint:

```ts
import { createXixo, metaCSRFToken } from "@xixo/client";
import { actionCableExchange } from "@xixo/client/actioncable";

export const client = createXixo({
  url: "/graphql",
  csrfToken: metaCSRFToken,
  onUnauthorized: () => signIn(),
  subscriptions: actionCableExchange(),
});
```

Run a typed document with the client:

```ts
import { SettingsDocument } from "@xixo/client";

const { data, error } = await client.query(SettingsDocument, {}).toPromise();
```

### React

```tsx
import { XixoProvider, useQuery } from "@xixo/client/react";
import { SettingsDocument } from "@xixo/client";

<XixoProvider client={client}>
  <App />
</XixoProvider>;

function Settings() {
  const { data, loading, error } = useQuery(SettingsDocument);

  if (loading) return <p>Loading</p>;
  if (error) return <p>{error.message}</p>;
  return <pre>{JSON.stringify(data, null, 2)}</pre>;
}
```

## API

### `@xixo/client`

| | |
| --- | --- |
| `createXixo(options)` | Returns a `XixoClient`, which is a urql `Client`. |
| `metaCSRFToken()` | Returns the `content` of the page's `<meta name="csrf-token">` tag, or `null`. |
| `XixoClient` | The client type. |
| `XixoOptions` | The options for `createXixo`. |
| `*Document` | A typed document for each query, mutation, and subscription, such as `CatalogDocument`, `SearchDocument`, and `AttachResourceDocument`. |

The package also exports the TypeScript types generated from the xixo GraphQL schema, including the
result and variables types for each document.

`XixoOptions` has these fields:

| | |
| --- | --- |
| `url` | The GraphQL endpoint. Required. |
| `csrfToken` | A function that returns the CSRF token, sent as the `X-CSRF-Token` header on every request. |
| `onUnauthorized` | Called when a request returns a 401 response. |
| `subscriptions` | A urql exchange for subscriptions, such as the one `actionCableExchange` returns. |

The client uses urql's document cache.

### `@xixo/client/react`

| | |
| --- | --- |
| `XixoProvider` | Puts a client in React context. |
| `useXixo()` | Returns the client from context. Throws outside a `XixoProvider`. |
| `useQuery(document, variables?, { skip? })` | Runs the query from the network whenever the variables change. Returns `{ data, loading, error, refetch }`. |
| `useMutation(document)` | Returns `{ execute, attempt, loading, error }`. `execute(variables)` resolves to the data or `null`. `attempt(variables)` resolves to `{ data, error }`. |
| `useSubscription(document, variables?, { skip? })` | Subscribes while mounted. Returns `{ data, error }` with the latest result. |

### `@xixo/client/actioncable`

| | |
| --- | --- |
| `actionCableExchange({ channel?, url? })` | Returns a urql subscription exchange over Action Cable. `channel` defaults to `GraphqlChannel`. Without a `url`, the consumer reads the page's `action-cable-url` meta tag, or connects to `/cable`. |

## Development

The types come from the schema of the xixo Rails app, so the package is built from a checkout of
[the xixo repository](https://github.com/xixo/xixo):

```sh
bin/rails graphql:dump_schema
npm run codegen
npm run build:sdk
```

`graphql:dump_schema` writes `web/schema.graphql`, `codegen` generates
`web/src/generated/graphql.ts` from it and the operations in `web/src/operations`, and `build:sdk`
compiles the package into `web/dist`.

## License

MIT.
