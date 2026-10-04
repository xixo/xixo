<p align="center"><img src="public/icon.svg" width="120" alt="The xixo mark"></p>

# xixo

An indexer for personal data. xixo reads the places your files and records live, builds one
searchable index across all of them with analysis attached, and can return the bytes as an export
or a local copy.

**Documentation: [docs.xixo.network](https://docs.xixo.network)**

```
app/              the Rails app       GraphQL, MCP, analyzers, resources, and jobs
app/javascript/   the browser app     React, urql, and the generated types
web/              xixo                the GraphQL and Action Cable client, on npm
docs/             the site above      Astro + Starlight
```

xixo signs people in through [masks](https://github.com/masksrb/masks). Each xixo tenant is a client
of a masks tenant, and every request to `/graphql`, `/mcp`, and `/uploads` carries a masks access
token.

## Interfaces

| Path       | Client                                       | Authorization                                        |
| ---------- | -------------------------------------------- | ---------------------------------------------------- |
| `/graphql` | The browser app, and [`xixo`](web/README.md) | A masks session, or a bearer token                   |
| `/mcp`     | An MCP client, such as Claude                | A masks token, with typed tools and per-token grants |

Both call the domain layer directly. MCP has typed tools of its own so that each one can be granted
separately. The TypeScript types are generated from the Ruby schema, so the type check fails when
the browser app drifts from the API.

## Resources

A resource is a place xixo reads from or writes to, such as a bucket, a mailbox, a model backend, or
an MCP server. Each type is a subclass of `Resource` in `app/models/resource/`.
[Resource types](https://docs.xixo.network/reference/resources/) lists every type.

## Running it

The server ships as a container image. Every push to main is published as `:main`, `:latest`, and
`:sha-<commit>`. It needs Postgres, OpenSearch, and a masks server, and it migrates itself on boot.

```sh
docker pull ghcr.io/xixo/xixo:latest
```

See [self-hosting](https://docs.xixo.network/guides/self-hosting/) for an example `compose.yml`, the
secrets, and tenants.

## Development

```sh
./dev       # http://xixo.localhost:8180, docs on :8181
./dev test  # unit, server, corpus, and client suites, in containers
```

`./dev` needs Docker with Compose, and Ruby. It runs Rails, Vite, the worker, the documentation
site, and three backing services (PostgreSQL, OpenSearch, and MinIO) in the foreground, all
reloading. One tenant answers at `xixo.localhost`. `./dev --multi` declares `demo` and `acme`
instead, at `demo.xixo.localhost:8180` and `acme.xixo.localhost:8180`. `*.localhost` already
resolves, so there is no `/etc/hosts` to edit.

Sign-in needs masks running too. From a masks checkout beside this one, run `../masks/dev`.
`MASKS_ISSUER` names the masks server. Models run on the host through Ollama, which `brew bundle`
installs. The [quickstart](https://docs.xixo.network/quickstart/) lists the models to pull.

`./dev test server` runs one suite. The Rails suites clear `XIXO_TENANT` and `XIXO_TENANTS`, so
they run against multiple tenants whichever way the stack was started. CI runs each suite through
`./dev test`.

`./dev reference` regenerates the reference pages under `docs/` from the code and checks the ENV
vars page against every variable the code reads. CI fails when either is stale.

## Configuration

Nothing in this repository names a host, a domain, or a secret. xixo reads all of them from the
environment. [ENV vars](https://docs.xixo.network/reference/environment/) lists every variable, and
`.env.example` gives development values.

`PLAN.md` lists open work. Prose follows [docs/STYLE.md](docs/STYLE.md).
