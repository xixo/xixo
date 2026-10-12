# xixo-agent

`xixo-agent` runs on a machine and connects it to xixo. It enrolls with masks
as a client of its own, reports the machine's health, offers the folders its
configuration names, and reads files in those folders when xixo asks. The
agent dials out to xixo, so the machine opens no port.

## Building

The agent is one static binary. It builds for Linux on amd64 and arm64:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.version=0.1.0" -o xixo-agent-linux-amd64 .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.version=0.1.0" -o xixo-agent-linux-arm64 .
```

`go test ./...` runs the tests.

## Files on the machine

| Path | Holds |
| --- | --- |
| `/usr/local/bin/xixo-agent` | The binary. |
| `/etc/xixo-agent/config.json` | Where xixo and masks are, and the folders the agent shares. |
| `/var/lib/xixo-agent/key.json` | The private key the agent signs its client assertions with. |
| `/var/lib/xixo-agent/dpop.json` | The private key the agent proves its tokens with. |
| `/var/lib/xixo-agent/registration.json` | The client masks registered for the agent, and its registration access token. |
| `/etc/systemd/system/xixo-agent.service` | The unit, from `xixo-agent.service` with `@USER@` and `@FOLDERS@` replaced. |

The state directory is mode 0700 and every file in it is mode 0600. The keys
are made on the machine the first time the agent enrolls and never leave it.

The configuration looks like this:

```json
{
  "xixo": "https://xixo.example.com",
  "issuer": "https://id.example.com",
  "folders": ["/srv/media", "/home/sam/Documents"]
}
```

Both addresses use https. Plain http is accepted only for a loopback host such
as `localhost` or a `.localhost` name. Each folder is an absolute path. The
configuration on the machine is the only place the shared folders are named:
xixo can read inside them and nowhere else, and nothing xixo sends changes the
list.

## Commands

`xixo-agent enroll --token - [--name NAME]` reads an enrollment token from
standard input, registers the agent's public key with masks, and saves the
registration. `--token` also takes the token itself, and the
`XIXO_ENROLLMENT_TOKEN` variable is read when the flag is empty. Standard input
keeps the token out of the process list. `--name` is the name masks shows for
the machine, and defaults to the hostname. Enrolling again registers a new
client with the same key and deletes the previous one.

`xixo-agent run` connects to xixo and serves it until it is stopped.

`xixo-agent version` prints the version.

`enroll` and `run` take `--config PATH` (default
`/etc/xixo-agent/config.json`) and `--state DIR` (default
`/var/lib/xixo-agent`).

## Signing in

The agent is a masks client that authenticates with `private_key_jwt` and
holds DPoP-bound tokens. `run` asks for a `client_credentials` token with the
scope `xixo:agent` and the resource `<xixo>/mcp`. It opens a websocket to
`<xixo>/cable` with the token in `Authorization: DPoP <token>`, a DPoP proof
for `GET <xixo>/cable` in the `DPoP` header, and xixo's origin in `Origin`.
When xixo answers with a `DPoP-Nonce`, the agent dials once more with a proof
naming that nonce.

Each connection uses a fresh token. Twenty seconds before the token expires,
the agent finishes the requests it is answering, refuses new ones, and
reconnects with a new token, so a client withdrawn in masks loses its
connection within one token lifetime. A failed connection is retried after a
jittered pause that doubles from one second up to one minute.

## The conversation with xixo

The agent speaks the Action Cable protocol and subscribes to
`{"channel":"AgentChannel"}`. Everything it sends is a `message` command whose
`data` is a JSON object with an `action`:

| Action | Fields | When |
| --- | --- | --- |
| `hello` | `version`, `os`, `arch`, `hostname`, `folders`, `services`, `extractors` | Once the subscription is confirmed. |
| `health` | `uptime`, `load`, `memory`, `disks` | After `hello`, and every minute. |
| `reply` | `request`, `ok`, `result` or `error` | When a request is answered. |
| `chunk` | `request`, `of`, `seq`, `data` | For each part of a file being read or made. |

`services` lists the model servers listening on the machine's loopback
address: `{"kind":"ollama","port":11434,"address":"100.64.0.7"}`, and
`lmstudio` on port 1234. `address` is the machine's tailnet IPv4 address when
`tailscale ip -4` answers, and empty otherwise.

`extractors` names the extractors whose programs are on the machine, so xixo
sends each file to an agent that can read it.

`health` holds `uptime` in seconds, `load` as the 1, 5, and 15 minute
averages, `memory` as `{"total","available"}` in bytes, and `disks` as
`[{"path","total","free"}]` in bytes for `/` and each shared folder.

xixo sends a request as the `message` of a broadcast on the subscription:

```json
{"request": "6c1d0a3e-0d5e-4f8e-9a51-7f1b6b1c2d3e", "verb": "list", "args": {"folder": "/srv/media"}}
```

| Verb | Args | Result |
| --- | --- | --- |
| `health` | none | The fields of a `health` message. |
| `list` | `folder`, `cursor`, `prefix`, `limit`, `skip` | `{"entries":[{"path","size","modified_at"}],"cursor"}` |
| `read` | `folder`, `path` | `chunk` messages, then `{"size"}` |
| `extract` | `source`, `size`, `mime`, `filename`, `skip`, `settings` | each made file's `chunk` messages, then the steps and the list of files |
| `derive` | as `extract` | the thumbnail and preview alone |

`list` walks the folder depth first in name order and returns at most `limit`
regular files, 500 at most. Paths are relative to the folder and
`modified_at` is RFC 3339 in UTC. A `cursor` in the result means more files
follow, and passing it back resumes after the last path returned. `prefix`
keeps the paths that start with it, and `skip` adds name patterns to the ones
that are always skipped.

`read` sends the file as `chunk` messages of at most 256 KiB, base64 encoded,
numbered from 0, followed by a reply holding the number of bytes sent.

An upload is a file xixo holds for the agent to read. `extract` names it as
`{"upload": id}` with its `size`, and the agent fetches
`<xixo>/agent/uploads/<id>` once over HTTPS with its token and a fresh DPoP
proof. The address is built from the configured xixo address and the id, which
must be a UUID, so the token never goes anywhere else, and a redirect is not
followed. The body goes into the extraction's private work directory, at most
4 GiB, and must be exactly `size` bytes. xixo serves an upload once, to the
machine it was staged for, within 15 minutes.

`extract` reads an upload (`{"upload": id}`) or a shared file
(`{"folder", "path"}`) and answers with its steps. Each file it makes, such as a
thumbnail, is sent first as `chunk` messages under a new id, with `of` naming
the `extract` request, and the reply lists the files with their role, name,
type, size, and that id. [internal/extract/README.md](internal/extract/README.md)
describes every step.

A refused request is answered with `"ok": false` and an `error`. The agent
refuses a folder its configuration does not name, a path that is absolute,
not in its shortest form, or outside the folder, a path through a symbolic
link, a path through a skipped name, and anything other than a regular file.

The agent never walks or reads symbolic links or these names: `.git`, `.hg`,
`.svn`, `node_modules`, `__pycache__`, `.venv`, `.tox`, `.Trash`, `.Trashes`,
`.Spotlight-V100`, `.fseventsd`, `.DS_Store`, `._*`, `Thumbs.db`, and
`desktop.ini`. It answers up to four requests at once.

## The service

`xixo-agent.service` runs `xixo-agent run` as the user named in place of
`@USER@`, which is the user who owns the shared folders. systemd creates the
state directory for that user, restarts the agent when it stops, and keeps it
from writing anywhere else, gaining privileges, or reaching devices. The agent
also runs in its own user namespace, sees no other process in `/proc`, and makes
only the system calls an ordinary service makes.

The installer writes a `BindReadOnlyPaths=` line in place of `@FOLDERS@`, one
quoted entry per shared folder. `/home`, `/root`, `/srv`, `/mnt`, `/media`,
`/opt`, and `/var/lib` are empty for the agent apart from its state directory,
and each shared folder is mounted back read-only, so a file outside them is
missing even when the agent's user could read it. This holds behind the agent's
own path checks.

When masks answers `invalid_client`, the machine was unenrolled, so the agent
exits with status 78 and the unit's `RestartPreventExitStatus=78` keeps it
stopped. Any other failure to reach masks or xixo is retried with backoff.
