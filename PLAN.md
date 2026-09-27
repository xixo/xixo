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

Each has the answer this plan assumes. Change one and the phase that depends on it changes.

- [ ] **A file's identity is its bytes and its owner.** Two originals share a feed exactly when
      they have the same join key, `(resources.owner_subject, digest)`. A tenant resource joins
      tenant resources, and a person's own resource joins only that person's. A feed never lists a
      personal place beside a shared one, so joining cannot tell others that a file sits in
      somebody's own Drive. The key stays a display name, and proposals do not come back.
- [ ] **One rule decides membership, in one place.** `Reference#settle!` runs when a digest is
      written and when a sync sees a new version. A reference with a digest joins the oldest feed
      holding its join key. A reference whose version just changed, on a feed with other
      originals, leaves for a feed of its own before anything analyzes it.
- [ ] **Joining is automatic, and splitting is the undo.** A place split off by hand is marked
      `kept_apart` and is not joined again until its bytes change.
- [ ] **The oldest feed survives.** Before its originals move, the absorbed feed's edges are added
      to the survivor, its note is appended by `keep_note_from`, and the later expiry is kept, with
      forever beating any date. Its analyses, passages, derived references, and children are
      destroyed with it, because they describe the bytes the survivor already describes.
- [ ] **Empty files, gone references, and archived resources do not join.** All three are left out
      of the join key, which is one scope, `Reference.joinable`.
- [ ] **Near duplicates are out of scope.** A re-encoded photo, a PDF and the DOCX it came from, and
      two files with one name and different bytes are related. They are a later plan, likely an
      edge found through embeddings.

## Phase 1: one join key, one lock

- [ ] `Fingerprint.lock!(digest)`, moved out of `Intake#alone!`, which requires a transaction
- [ ] `Reference#fingerprint!(io = download)`, moved out of `DigestReferencesJob#fingerprint`, with
      the same version guard
- [ ] `Reference.joinable`: originals, not gone, on active resources, with a digest that is not the
      empty file's, and not `kept_apart`
- [ ] `Intake#twin_of` finds its twin through `Reference.joinable` with the tenant's owner. Today it
      takes any resource the uploader can see, so an upload can land on a feed whose only place is
      the uploader's personal resource, and placing it in tenant storage puts a shared place beside
      a personal one

## Phase 2: join

- [ ] `Reference#settle!`, under `Fingerprint.lock!`. It finds the oldest feed with a joinable
      original on the same join key, adds the absorbed feed's edges, note, and expiry to it, moves
      the absorbed originals in one `update_all`, destroys the emptied feed, and reindexes the
      survivor once with `Feed.reindex!`. `move_to!` per row would reindex per row and clear the
      survivor's `embedded_at`, so a join of identical bytes would embed it again
- [ ] `fingerprint!` and `Placement#recorded` call `settle!` after writing the digest
- [ ] Each join writes `AuditEvent.record(channel: "job")`, as `ForgetExpiredJob` does, naming the
      survivor, the absorbed feeds, and the digest
- [ ] What the catalog already holds: a job enqueued once by the migration that adds `kept_apart`
      settles one reference per joinable digest held by more than one feed, per tenant
- [ ] Tests: two resources, one file, one feed; three copies across two owners make two feeds;
      empty files stay apart; a join never crosses tenants; edges survive the absorbed feed's
      `forget_edges`; note and expiry follow the rules above; the search index holds the survivor
      and not the absorbed feed; the survivor keeps its `embedded_at`

## Phase 3: leave, and keep apart

- [ ] `Resource#keep!` calls `settle!` after `Reference.discover!` has saved, and before `analyze!`.
      A reference whose version changed in that discover, on a feed with other originals, `split!`s
      into a feed that `connect!`s to everything the old feed connects to and takes its note.
      Edges are the same rule both ways: a join takes the union, and a leave copies them all.
      `note_version!` stays a setter
- [ ] `feed_references.kept_apart`. `Mutations::SplitReference` sets it; `note_version!` clears it
      where it clears the digest. The split in `keep!` does not set it
- [ ] The Split button in `ItemDetail.tsx` becomes "Keep apart", its toast says the place stays
      apart until its bytes change, and the places list says a place was joined because the bytes
      are the same
- [ ] Tests: an edited copy leaves with every edge and the note, and is analyzed alone; a kept-apart place stays apart through a
      settle and joins again after an edit

## Phase 4: analysis settles what it reads

A sync analyzes a new or changed file straight away, and `DigestReferencesJob` reaches it later,
twenty at a time. Without this phase, each duplicate is analyzed before it joins, and a file
touched with the same bytes leaves, is analyzed, and joins again.

- [ ] In its reading phase, the analyzer hashes the tempfile `keeping_download` already holds with
      `fingerprint!` when the original has no digest, so the digest costs no second download. If
      `settle!` absorbs the feed, the analysis writes one step naming the survivor with
      `write_step!`, as `Placement#noted` does, and finishes without running the rest
- [ ] Holdings, the catalog counts, and export count feeds. Check each one reads right as joins
      land
- [ ] Tests: a second resource holding an analyzed file adds a reference and runs no analysis
      steps; a touched file with the same bytes rejoins without analysis

## Phase 5: say so

- [ ] `docs/src/content/docs/concepts/references.mdx` gains a section on joining: the join key,
      what survives, leaving, and keeping apart. "Moving between feeds" stops saying that sync and
      export are the only things that move references
- [ ] `splitReference` gets a description, `ReferenceType` gains a described `digest` field, and
      `bin/rails docs:reference` regenerates the GraphQL reference

## Verification

- The suite, with each phase's tests, plus these mutations each caught by a test: dropping the
  owner from the join key, dropping the empty-file rule, joining a kept-apart reference, and
  skipping the lock while analysis and the digest job settle the same digest
- Live in the dev stack: attach two filesystem resources over one folder, sync both, and watch one
  feed per file appear with two places; edit one file and watch it leave; keep a place apart and
  sync again

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
