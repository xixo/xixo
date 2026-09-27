# The same bytes are one feed

A file synced from two resources, or synced once and uploaded again, is one feed with two
references. uris decides which feed a reference belongs to whenever its digest is written or
cleared, and a person can keep a place apart.

Written 2026-09-27, replacing "Somebody else's account, through masks", whose phases all landed.
Its two open decisions and its known gaps are carried to the bottom of this one. Ordered by
dependency; each phase is usable on its own and the one after it assumes the one before landed.

## Where this starts

Duplicates were proposed and merged by hand from 2026-08-31 and removed on 2026-09-08 (`6196e11`),
because a proposal asked an identity question the schema had not answered. For a `uris:file` it
still has not: the key is the basename the file was found under, and a file synced from two
resources is two feeds, analyzed twice, tagged twice, and counted twice.

What exists to build on:

- `feed_references.digest` is the SHA-256 of an original's bytes, indexed on `(tenant_id, digest)`.
  `DigestReferencesJob#fingerprint` writes it, guarded on the version it read, and `Placement`
  copies it from the upload.
- `Reference#note_version!` clears the digest when a sync reports a new version.
- `Intake` with `unique` set returns the existing feed as a duplicate for bytes it has seen, under
  `alone!`, a transaction-scoped advisory lock on `tenant:digest`.
- `Reference#move_to!` destroys a file feed once its last original leaves, and `split!` survived
  the removal. The Split button on the item page reaches it through `splitReference`.
- `6196e11^:app/models/feed.rb#merge!` has the note rule, `keep_note_from`.

## Decisions

Decided 2026-09-27, and built the same day.

- [x] **A file's identity is its bytes and its owner.** Two originals share a feed exactly when
      they have the same join key, `(resources.owner_subject, digest)`. A tenant resource joins
      tenant resources, and a person's own resource joins only that person's. A feed never lists a
      personal place beside a shared one, so joining cannot tell others that a file sits in
      somebody's own Drive. The key stays a display name, and proposals do not come back.
- [x] **Membership is decided where the digest changes.** `Reference#settle!` joins, and runs
      wherever a digest is written. `Reference#leave!` runs where a sync sees a new version: an
      original on a feed with other originals leaves for a feed of its own before anything
      analyzes it.
- [x] **Joining is automatic, and splitting is the undo.** A place split off by hand is marked
      `kept_apart` and is not joined again until its bytes change.
- [x] **The oldest feed survives.** Before its originals move, the absorbed feed's edges are added
      to the survivor, its note is appended by `keep_note_from`, and the later expiry is kept, with
      forever beating any date. Its analyses, passages, derived references, and children are
      destroyed with it, because they describe the bytes the survivor already describes. A
      survivor with no finished analysis and none open is analyzed.
- [x] **Connections are one rule both ways.** A join takes the union of the edges, and a split,
      by hand or on a new version, copies them all to the new feed along with the note and expiry.
- [x] **Empty files, gone references, archived resources, and uris' own stores do not join.** All
      four are left out of one scope, `Reference.joinable`. The internal `children` store holds the
      originals of files extracted from an archive, and without this a member of a zip would join a
      copy elsewhere and leave its archive.
- [x] **A feed with an analysis open is not absorbed** by anyone but that analysis, which settles
      its own feed before it reads and stops if the feed joins another.
- [x] **Near duplicates are out of scope.** A re-encoded photo, a PDF and the DOCX it came from, and
      two files with one name and different bytes are related. They are a later plan, likely an
      edge found through embeddings.

## Phase 1: one join key, one lock

- [x] `Fingerprint.lock!(digest)`, moved out of `Intake#alone!`, refuses to run outside a
      transaction
- [x] `Reference#fingerprint!`, moved out of `DigestReferencesJob#fingerprint`, with the same
      version guard
- [x] `Reference.joinable`, and `Resource.external` for everything but uris' own stores
- [x] `Intake#twin_of` finds its twin through `Reference.joinable` on the tenant's shared
      resources. It used to take any resource the uploader could see, so an upload could land on a
      feed whose only place was the uploader's personal resource

## Phase 2: join

- [x] `Reference#settle!` under `Fingerprint.lock!`, and `Feed#absorb!`, which moves the originals
      in one `update_all` so the survivor is reindexed once with `Feed.reindex!` and keeps its
      `embedded_at`
- [x] `DigestReferencesJob` settles what it fingerprints. `Placement` does not settle: the upload
      it places belongs to a feed still being analyzed, so the analysis settles its originals once
      it has filed them
- [x] Each join writes a `join_feeds` audit event naming the survivor, the absorbed feed, and the
      digest
- [x] `SettleTwinsJob`, enqueued once by the migration that adds `kept_apart`, settles what the
      catalog already holds

## Phase 3: leave, and keep apart

- [x] `Resource#keep!` calls `leave!` when `discover!` saw a new version, before `analyze!`
- [x] `feed_references.kept_apart`. `splitReference` sets it; `note_version!` clears it where it
      clears the digest
- [x] The Split button is "Keep apart", and a place with the same bytes as another says so

## Phase 4: analysis settles what it reads

- [x] `AnalyzeFeedJob` fingerprints the original before it reads, when it has no digest, and
      settles it. If the feed joins an older one, the analysis finishes and goes with the feed,
      and the audit event records where it went. The fingerprint is a download of its own; it
      replaces the one `DigestReferencesJob` would otherwise make, so no file is read more times
      than before. Hashing the analyzer's kept tempfile instead would save that download and is
      not done
- [x] Holdings, the catalog counts, and export count feeds, so they count a joined file once

## Phase 5: say so

- [x] `docs/src/content/docs/concepts/references.mdx` covers joining, leaving, and keeping apart
- [x] `splitReference`'s argument and `ReferenceType.digest` are described, and the GraphQL
      reference is regenerated

## Verification

- `test/unit/models/twins_test.rb` and an upload case in `test/server/uploads_test.rb`. Each of
  these mutations is caught: dropping the owner from the join key, dropping the empty-file rule,
  joining a kept-apart reference, joining uris' own stores, skipping the join before an analysis
  reads, and skipping the leave. Skipping the lock is not caught; no test races two settles
- Live in the dev stack: attach two filesystem resources over one folder, sync both, and watch one
  feed per file appear with two places; edit one file and watch it leave; keep a place apart and
  sync again. Not yet run

## Decisions carried

- [ ] **Does an MCP server's authorization server say who somebody is?** The gate needs a stable
      subject. `mcp.notion.com` registers its clients dynamically and runs PKCE, but it is its own
      authorization server, not Notion's public OAuth, and may hand back nothing that names the
      Notion user. Masks' `Federation::Mcp` takes it as anonymous unless the provider names a
      `userinfo_url`, so today a Notion MCP connection is gated on the masks actor alone. Whether
      that is enough is still to decide.
- [ ] **What re-analysis costs.** An analysis that writes an edge re-analyzes the feed on the other
      side, which cascades without a cooldown. Per-feed cooldown, a depth cap, or a cause that
      refuses to write edges.

## Known gaps, recorded rather than fixed

The first was found writing this plan; the rest are carried from the last one.

- **A personal resource's places show on the tenant's catalog.** A sync of a personal resource
  writes into the shared catalog, and `FeedType.references` lists every place to anyone who can
  read the catalog. Joining keeps owners apart so it does not make this worse, and it does not fix
  it.
- **The headless browser resolves hosts for itself.** Git and the MCP client are pinned to the
  vetted address now; the browser checks every request it makes, which narrows the window but
  does not close it.
- **Nothing sweeps an analysis past its deadline**, and nothing sets one `gated`.
- **`origin: "feed"` is never written.**
- **`SearchIndex.document` asks for a feed's tags one query at a time.**
- **An edge does not re-analyze the feed on the other side**, pending the cost decision.
- **A feed with no reference has no `analyzed_at`.**
- **Something deleted at the source is marked gone, never removed.** A finished sync sets `gone_at`
  on what it did not see; nothing yet forgets a feed whose every place is gone.
- **Only git, IMAP, GitHub, and OneDrive walk what changed.** Notion and Slack still walk everything.
- **A OneDrive folder renamed between full walks leaves its files' paths stale.** Graph reports the
  folder and not what is under it, and items are keyed on their id, so nothing is duplicated; the
  next full walk, at most a day later, puts the paths right. A file under a folder moved out of
  the resource's folder is likewise noticed as gone only by that full walk.
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
- **An export into a resource ignores its prefix.** It writes at the original's own path, so a
  sync of the destination never takes a copy for an original. A caller's `put` is bounded.
- **Errors carry the address they failed on**, userinfo included for the types that do not refuse
  it.
