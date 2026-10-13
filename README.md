<p align="center"><img src="public/icon.svg" width="120" alt="The xixo mark"></p>

# xixo

xixo builds one searchable index across the places your files and records live. It reads each
place, analyzes what it finds with local models, and lets you search, ask, and act on all of it
from the browser or from an agent like Claude.

**Documentation: [docs.xixo.network](https://docs.xixo.network)**

## The code

```
app/models/           feeds, analysis, and tenants
app/models/resource/  each place xixo reads from or writes to
app/analyzers/        what turns a file into text, tags, and a summary
app/tools/            the tools an agent calls over MCP
app/graphql/          the API the browser app uses
app/jobs/             syncing, analysis, and export, run by Solid Queue
app/javascript/       the browser app, in React
web/                  the TypeScript client for the API, published on npm
link/                 xixo link, the Go program that connects a machine to xixo
docs/                 docs.xixo.network, in Astro
lib/tenancy/          how every row and job stays inside its tenant
test/                 the unit, server, embedded, corpus, and client suites
```

xixo is a Rails app. It stores its data in PostgreSQL and its search index in OpenSearch. People
sign in through [masks](https://github.com/masksrb/masks), which xixo serves at `/id`.
`MASKS_ISSUER_TEMPLATE` points it at a separate masks server instead.

## Development

```sh
./dev       # http://xixo.localhost:8180
./dev test  # every suite, in containers
```

[Development](https://docs.xixo.network/reference/development/) covers the rest. Prose follows
[docs/STYLE.md](docs/STYLE.md).
