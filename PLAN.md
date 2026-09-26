# Somebody else's account, through masks

A resource that acts as a person somewhere else — their Notion, their Drive, their OneDrive —
reaches that account through the identity masks holds for them, and uris never runs an OAuth
flow of its own.

Written 2026-09-13, replacing "One record, one pass", which finished 2026-09-12. Its open decision
and the gaps it recorded are carried to the bottom of this one. Ordered by dependency; each phase
is usable on its own and the one after it assumes the one before landed.

Background: masks `47a211b` took upstream tokens out of masks the same day — `POST
/connections/token`, `/connections/:provider/start`, the `masks:connections:*` scopes and the token
columns on `Connection`. uris's `Broker`, `Resource::Brokered`, `Enrollment`, `oauth-google` and
`microsoft-graph` are built on exactly those, so both types are dead against masks as it stands.
Nothing noticed: every uris test talks to `test/support/fake_broker_server.rb`, and `Gemfile.lock`
pins masks at `6c604ea`, from before the removal. This plan brings the tokens back into masks, and
fixes what made them worth removing.

## What the old broker got wrong

- **It released a token to any bearer holding `masks:connections:<provider>`.** A scope says what
  kind of thing a token may do, not whose account it may do it to or which application asked.
- **Masks sat on every upstream call**, since nothing downstream kept what it was handed.

A delegation is narrower on both counts. A token is released to one registered client, for one
connection, which that connection's owner consented to that client using. uris holds the upstream
access token until it expires, so masks is asked when one runs out rather than per call.

## Decisions still open

- [x] **Upstream tokens live in masks.** Not in uris per resource. Masks already knows the
      identity, already links it, and is the one place a person can see and withdraw what every
      application does with it. Decided 2026-09-13.
- [x] **Connecting is gated on the identity.** Only the person whose masks account holds the
      linked Notion (or Google, or Microsoft) identity can connect a resource to it. Decided
      2026-09-13.
- [x] **Google Drive and OneDrive move onto the same flow** rather than being deleted. Decided
      2026-09-13.
- [x] **A resource is the tenant's or a person's**, chosen by whoever connects it. Decided
      2026-09-13.
- [x] **The seam is a masks client library.** uris calls it and knows nothing of the wire; masks
      ships it with a fake for uris' suite, the way `FakeIssuer` stands in for sign-in. Decided
      2026-09-13.
- [ ] **Does an MCP server's authorization server say who somebody is?** The gate needs a stable
      subject. `mcp.notion.com` registers its clients dynamically and runs PKCE, but it is its own
      authorization server, not Notion's public OAuth, and may hand back nothing that names the
      Notion user. Masks' `Federation::Mcp` takes it as anonymous unless the provider names a
      `userinfo_url`, so today a Notion MCP connection is gated on the masks actor alone. Phase 6
      runs it for real; whether that is enough is still to decide.
- [x] **What the client library is called and shaped like.** `Masks::Client::Delegations`, in
      the masks gem: `start`, `finish` and `token`, `Refused` and `Unavailable` each carrying any
      rotated secret, and `Delegations::Fake`. Decided 2026-09-13.
- [ ] **Whose personal resources a feed may use.** A feed run in the background has no grant. It
      needs to know who made it — `Feed` records no `created_by` today — and whether an agent run
      for that person may reach their personal resources, or only the tenant's.
      Until it is decided, an agent run's grant speaks for `feed:<key>`, which owns nothing, so it
      reaches only the tenant's resources.
- [ ] **What re-analysis costs.** Carried from the last plan. An analysis that writes an edge
      re-analyzes the feed on the other side, which cascades without a cooldown. Per-feed cooldown,
      a depth cap, or a cause that refuses to write edges.

## Phase 0 — keep one thing

Independent of masks, so it lands first. Today a resource is synced whole or not at all; its
`list` and `get` let an agent look without keeping anything.

- [x] `object_for(id)` on the syncable types, answering the object `each_page` yields, so the
      locator, key, mime, title and version come out the same way a sync would make them. Notion
      first — one page lookup — then GitHub, Slack, S3, the filesystem, WebDAV and git
- [x] The body of `SyncResourceJob#each_iteration` — `Reference.discover!`, then
      `awaiting_analysis?`, then `analyze!` — becomes a method on the resource both call, so a kept
      object and a synced one cannot drift apart
- [x] `keep` in each type's `command_schema`, and in `Tool::Resources::WRITE`
- [x] A kept object is found again by the next full sync rather than duplicated, and changes are
      noticed on it like any other

## Phase 1 — the client library

Masks' work; recorded here so the two sides agree on what crosses. Landed in masks `4b7048c`,
`912e856` and `738fba6`; see masks' `concepts/delegation` page for what it became.

What uris needs from the library:

- **Start connecting** — given a provider key and a return URL, an authorize URL and the state to
  keep across the redirect.
- **Finish connecting** — given the callback parameters and that state, a held delegation: the
  connection, its provider, the subject that connected, and a secret for uris to keep encrypted.
- **A token** — given a held delegation, a live upstream access token and when it expires, with
  nobody signed in, and a replacement secret whenever the old one rotates.
- **Two kinds of refusal** — refused (the connection was revoked, the identity unlinked, consent
  withdrawn, the actor gone), which a person has to fix, and unavailable, which is worth retrying.
- **A fake**, so uris' suite stops keeping a fake of masks' internals.

What the library does underneath, as far as uris cares:

- The person goes to masks `/authorize` with PKCE, asking for
  `openid offline_access masks:delegate:<provider>`. Masks shows the consent, links the provider
  first through `Linking` if the person has no live connection to it, and sends a code back.
- The code is redeemed for a masks refresh token whose grant is bound to the client, the actor and
  the connection.
- A token is a refresh, then an RFC 8693 exchange — masks' `Exchange` already takes one — with the
  masks access token as `subject_token`, the connection as `audience`, and an upstream token type
  as `requested_token_type`. Masks refreshes the upstream token itself.

What masks has to hold, in outline:

- Encrypted access and refresh tokens back on `Connection`, only for a provider that delegates
  access and names the API scopes it asks for beyond identity.
- A `Delegation` — client, actor, connection, when consented and when revoked — made at consent,
  listed and revocable from the account page and the manage API. Dynamically registered clients
  cannot hold `masks:` scopes, so only an approved client can be delegated to.
- `ExchangePolicy` releasing an upstream token only when the client may exchange, the subject token
  carries `masks:delegate:<provider>`, its actor owns the live connection named, and a live
  delegation exists for all three. Every release is an event.
- Providers whose authorization server is an MCP server's own, found from
  `/.well-known/oauth-protected-resource`, with masks registering itself as their client.

## Phase 2 — delegation replaces the broker

- [x] Delete `Broker`, `Resource::Brokered`, `Enrollment`, `EnrollmentsController`, the `/enroll`
      routes, `enrollResource`, `fake_broker_server.rb` and their tests
- [x] `Resource::Delegated`: the held delegation, the cached access token and its expiry in
      `credentials`, which are already encrypted. `upstream_token` answers the cache until it
      expires, then asks the library, and writes back what changed. `token_expired!` clears the
      cache for `Api#answer`'s one retry
- [x] A refusal sets `needs_connect_at` and raises `Resource::Unusable`, so `SyncResourceJob` stops
      rather than retrying it five times; a check or a sync that succeeds clears it
- [x] `Tenant#issuer` from `MASKS_ISSUER_TEMPLATE`, so a job with no request can reach masks. This
      is what OneDrive's background sync has been missing — `Broker.release` read `Current.issuer`,
      which only a request sets
- [x] `GET /resources/:id/connect`, behind `uris:resources:command`, keeps the library's state in
      the session bound to the resource and the subject, and redirects. `GET /connect/callback`
      refuses a state or a subject that does not match, and saves the delegation with
      `connected_by`
- [x] `attachResource` takes a delegated type and makes it unconnected; `connectResource` answers
      the address; `ResourceType` carries `connected`, `needsConnect` and `connectedBy`
- [x] `Attach.tsx` offers **Connect** where it offered a sign-in link, and a resource that needs it
      shows **Reconnect**

## Phase 3 — Google Drive and OneDrive

- [x] `oauth-google` and `microsoft-graph` include `Delegated` in place of `Brokered`, naming masks'
      `google` and `microsoft` providers. Their API calls do not change
- [x] `microsoft_graph_resource_test.rb` runs against the library's fake
- [x] OneDrive syncs on a schedule, with nobody signed in

## Phase 4 — an MCP server through masks

- [x] `Resource::Mcp` takes an optional provider. With one, its bearer is `upstream_token` rather
      than a pasted token, and a 401 clears the cache and tries once more
- [x] A pasted token keeps working as it does today
- [x] The `mcp` gem's own OAuth flow stays unused: it blocks a thread across the browser round
      trip, which suits a CLI rather than a request, and its discovery and token calls go through
      a client of its own, past `PublicAddress`

## Phase 5 — a person's resources

- [x] `resources.owner_subject`, empty for the tenant's; connecting offers "only me" or "everyone
      here"
- [x] `Resource.visible_to(grant)` — the tenant's, and the grant subject's own — replaces
      `Resource.attended.active` everywhere a person or a tool names a resource: the GraphQL
      mutations and query, `Tool::Resources`, `Tool::Base`, `Tool::Feeds`
- [x] `Grant#proxied` offers a personal MCP server's tools to its owner alone
- [x] A sync of a personal resource writes into the tenant's catalog like any sync; what an agent
      run may reach waits on the open decision above

## Phase 6 — the two sides, for real

Every phase above is proven against `Masks::Client::Delegations::Fake`, and a fake is how the old
broker went dead with nothing noticing. This phase runs the whole of it across both dev stacks —
masks on :12345, uris on :8180 — against an MCP server that runs its own authorization server, and
fixes whatever the fakes were hiding.

- [x] Track masks at its head in both lockfiles. Resolved by the release: uris takes masks
      `~> 0.7` from rubygems, and dev builds against the sibling checkout
- [x] An MCP server with an authorization server of its own: `script/mcp_oauth_server.rb`, which
      the dev stack runs as `mcp-oauth` at `mcp.localhost:8190`
- [x] The dev masks set up past its first-run screen, and the dev `uris` tenant paired with it
- [x] A provider in masks of protocol `mcp`, found from that server's metadata, with masks
      registering itself as the server's client
- [x] Attach an MCP resource in uris authenticating through masks, press **Connect**, consent in
      masks, come back connected; check it, and call one of its tools over MCP
- [x] With nobody signed in: restart `uris-worker` and let `ScheduleChecksJob` check it
- [x] Past the token's lifetime, a tool call still answers, and the session pool starts a new
      upstream session on the new token
- [x] Revoke the delegation from the masks account page; the next call leaves the resource needing
      a connection, and the resource list offers **Reconnect**
- [x] Attached as "only me", its tools are absent for another person's grant
- [x] What the run needs, written down: `./dev delegation`

Run for real on 2026-09-26. What the fakes had been hiding:

- **masks refused an http provider under `.localhost`.** `Provider` counted only the literal
  loopback names, where `Client` and `Handshake` also counted `.localhost`. They share
  `Client.loopback?` now (masks `c2690f6`).
- **uris could reach a private MCP server only by lifting the address guard for every type.**
  `URIS_MCP_ORIGINS` names the origins that may be private, as `URIS_S3_ORIGINS` does for storage.

## Verification

- The library's fake answering connect, token, rotation and both refusals; a cached token reused
  and an expired one replaced; a refusal marking the resource and stopping the job; a background
  sync with no `Current`
- The connect flow end to end against `FakeIssuer`: the redirect, a wrong state refused, a
  different subject refused, the delegation saved
- A personal resource absent for another subject in GraphQL, the resource tool and the proxied
  tools
- `keep` cataloguing one Notion page with a version, and the next sync noticing its edit
- Live, across both dev stacks, as phase 6 lays out

## Known gaps, recorded rather than fixed

Carried from the last plan, and from a sweep of the resource types on 2026-09-13 that fixed the
rest of what it found.

- **The headless browser resolves hosts for itself.** Git and the MCP client are pinned to the
  vetted address now; the browser checks every request it makes, which narrows the window but
  does not close it.
- **Nothing sweeps an analysis past its deadline**, and nothing sets one `gated`.
- **`origin: "feed"` is never written.**
- **`SearchIndex.document` asks for a feed's tags one query at a time.**
- **An edge does not re-analyze the feed on the other side**, pending the cost decision.
- **A feed with no reference has no `analyzed_at`.**
- **Something deleted at the source is marked gone, never removed.** A finished sync sets `gone_at`
  on what it did not see; nothing yet forgets a feed whose every place is gone, and Graph's delta
  still throws away the deletions it is handed, so OneDrive notices none.
- **Only git, IMAP and GitHub walk what changed.** Notion and Slack still walk everything, and Graph
  still discards its `deltaLink`, which is also how it would learn of deletions.
- **Graph keys are probably bare filenames.** A delta response omits `parentReference.path`, so two
  files of one name in different folders would share a key; the tests supply the path and cannot
  see it.
- **Truncation is silent.** Fifty GitHub comments, two thousand Notion blocks three deep, git blobs
  under two megabytes, the first thousand Slack users named.
- **A resource cannot be edited or deleted**, only archived and attached again under another key.
- **`declare!` runs on every boot** and takes default storage back for `files` from whatever was
  chosen since.
- **Fetches from fixed or operator-named hosts are not streamed.** `Resource::Api` and
  `openai-compatible` read a whole body before any cap, unlike `PublicFetch`.
- **A revoked delegation reaches uris only when its cached upstream token lapses.** uris keeps
  using the token it holds until 60 seconds before expiry, so a revocation in masks takes effect
  within one upstream token lifetime. Masks has no way to tell uris sooner.
- **The stand-in MCP server forgets its clients when it restarts**, so masks' registration with it
  goes stale. `./dev delegation` registers afresh on every run.
- **Errors carry the address they failed on**, userinfo included for the types that do not refuse
  it.
