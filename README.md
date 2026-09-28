<p align="center"><img src="public/icon.svg" width="120" alt="The uris mark"></p>

# uris

An indexer for personal data. uris reads the places your files and records live, builds one
searchable index across all of them with analysis attached, and can return the bytes as an export
or a local copy.

**Documentation: [uris.pages.dev](https://uris.pages.dev)**

```
app/              the Rails app       GraphQL, MCP, analyzers, resources, and jobs
app/javascript/   the browser app     React, urql, and the generated types
web/              @uris-to/client     the GraphQL and Action Cable client, on npm
docs/             the site above      Astro + Starlight
```

uris signs people in through [masks](https://github.com/masksrb/masks). Each uris tenant is a client
of a masks tenant, and every request to `/graphql`, `/mcp`, and `/uploads` carries a masks access
token.

## Interfaces

| Path       | Client                                                  | Authorization                                        |
| ---------- | ------------------------------------------------------- | ---------------------------------------------------- |
| `/graphql` | The browser app, and [`@uris-to/client`](web/README.md) | A masks session, or a bearer token                   |
| `/mcp`     | An MCP client, such as Claude                           | A masks token, with typed tools and per-token grants |

Both call the domain layer directly. uris does not expose GraphQL as an MCP tool, because a single
passthrough tool cannot be partially granted. The Ruby schema is the source of truth, and the
TypeScript types are generated from it, so the type check fails when the browser app drifts from
the API.

## Resources

A resource is a place uris reads from or writes to, such as a bucket, a mailbox, a model backend, or
an MCP server. Each type is a subclass of `Resource` in `app/models/resource/` that declares what it
serves and accepts. The API types (`github`, `notion`, `slack`, `oauth-google`, and
`microsoft-graph`) share `Resource::Api`, which makes the HTTPS request, checks the host, caps the
response size, retries once after a 401 when the token has expired, and raises a failure on a 429
that the job retries with backoff. Jobs that walk an unbounded number of records use
[job-iteration](https://github.com/Shopify/job-iteration), and resume from their cursor after a
deploy. [Resource types](https://uris.pages.dev/reference/resources/) lists every type.

## Running it

The server ships as a container image. Every push to main is published as `:main`, `:latest`, and
`:sha-<commit>`. It needs Postgres, OpenSearch, and a masks server, and it migrates itself on boot.

```sh
docker pull ghcr.io/urisrb/uris:latest
```

See [self-hosting](https://uris.pages.dev/guides/self-hosting/) for an example `compose.yml`, the
secrets, and tenants.

## Development

```sh
./dev       # http://uris.localhost:8180, docs on :8181
./dev test  # unit, server, corpus, and client suites, in containers
```

`./dev` needs Docker with Compose, and Ruby. It runs Rails, Vite, the worker, the documentation
site, and three backing services (PostgreSQL, OpenSearch, and MinIO) in the foreground, all
reloading. One tenant answers at `uris.localhost`. `./dev --multi` declares `demo` and `acme`
instead, at `demo.uris.localhost:8180` and `acme.uris.localhost:8180`. `*.localhost` already
resolves, so there is no `/etc/hosts` to edit.

Sign-in needs masks running too. From a masks checkout beside this one, run `../masks/dev`.
`MASKS_ISSUER` names the masks server. Models run on the host through Ollama, which `brew bundle`
installs. The [quickstart](https://uris.pages.dev/quickstart/) lists the models to pull.

`./dev test server` runs one suite. The Rails suites clear `URIS_TENANT` and `URIS_TENANTS`, so
they run against multiple tenants whichever way the stack was started. CI runs each suite the same
way.

`./dev reference` regenerates the reference pages under `docs/` from the code and checks the ENV
vars page against every variable the code reads. CI fails when either is stale.

## Configuration

Nothing in this repository names a host, a domain, or a secret. uris reads all of them from the
environment. [ENV vars](https://uris.pages.dev/reference/environment/) lists every variable, and
`.env.example` gives development values.

`PLAN.md` holds the plan in progress. Prose follows [docs/STYLE.md](docs/STYLE.md).
