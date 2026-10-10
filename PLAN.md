# What is left

The plan that made the same bytes one feed has landed. The
[references concept page](docs/src/content/docs/concepts/references.mdx) describes joining, leaving,
and keeping apart. This file lists what is still open.

## Next

- **A resource behind a transport that comes and goes.** A peer that is off fails each check with a
  connection error. Read the peer's state from tailscaled, report the resource as offline for that
  reason, and resume its syncs when the peer returns.
- **An agent.** A program on each machine that enrolls with xixo as a masks client, dials xixo, and
  reports the machine's health. It then offers the machine's folders and model server as resources
  reached through it, and later pulls analysis jobs, so a file is read where it lives and only its
  text reaches xixo. It runs natively on macOS, where a container cannot see the GPU or the real
  disks, and may run in a container on Linux.
- **Installing xixo on a phone.** A web manifest, an icon, and a share target.
- **Discovery.** A transport offers what it can reach as resources to attach, such as a tailnet's
  nodes from tailscaled's status.

## Not yet verified

- **Joining has not been run live.** Attach two filesystem resources over one folder, sync both, and
  check that each file is one feed with two places. Edit one file and check that it leaves. Keep a
  place apart and sync again.
- **No test races two settles**, so removing `Fingerprint.lock!` passes the suite.

## Undecided

- **Does an MCP server's authorization server say who somebody is?** `mcp.notion.com` registers its
  clients dynamically and is its own authorization server, so it may return nothing that names the
  Notion user. masks' `Federation::Mcp` treats it as anonymous unless the provider names a
  `userinfo_url`, so a Notion MCP connection is gated on the masks actor alone.
- **An edge does not re-analyze the feed on the other side.** Doing so cascades, so it needs a
  per-feed cooldown, a depth cap, or a cause that does not write edges.

## Known gaps

- **The headless browser resolves hosts for itself.** `Snapshot` checks each request it intercepts,
  and git and the MCP client are pinned to the vetted address.
- **Nothing sets an analysis `gated`.** `Gated` marks the run.
- **`SearchIndex.document` reads a feed's tags with one query per feed.**
- **Something deleted at the source is marked gone and never removed.** Nothing forgets a feed whose
  every place has a `gone_at`.
- **Only git, IMAP, GitHub, and OneDrive walk what changed.** Notion and Slack walk everything.
- **A OneDrive folder renamed between full walks leaves its files' paths stale** until the next full
  walk, at most a day later. A file under a folder moved out of the resource's folder is noticed as
  gone only by that walk.
- **Truncation is silent.** GitHub reads 50 comments, Notion 2,000 blocks three deep, git skips
  blobs over 2 MB, and Slack names the first 1,000 users.
- **A resource cannot be deleted**, only archived and attached again under another key.
- **A revoked delegation reaches xixo only when its cached upstream token lapses.** xixo uses the
  token until `Resource::Delegated::LEEWAY` before it expires, and masks has no way to tell it sooner.
- **The stand-in MCP server forgets its clients when it restarts.** `./dev delegation` registers
  again on every run.
- **An export into a resource ignores its prefix.** `upload` writes at the original's own path, so a
  sync of the destination never takes the copy for an original.
- **Errors carry the address they failed on**, userinfo included for the types that do not refuse it.
