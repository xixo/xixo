# The same bytes are one feed

A file synced from two resources, or synced once and uploaded again, is one feed with two
references. uris notices this from the bytes and joins the two feeds itself, and a person can keep
them apart.

Written 2026-09-27, replacing "Somebody else's account, through masks", whose phases all landed.
Its two open decisions and its known gaps are carried to the bottom of this one. Ordered by
dependency; each phase is usable on its own and the one after it assumes the one before landed.

## Where this starts

Duplicates were proposed and merged by hand from 2026-08-31 (`28fe996`, `a1a5c6a`) and removed on
2026-09-08 (`6196e11`). The proposals grouped on two keys, the same basename or the same reported
version, and a person settled each one. That was removed because identity had become `(type, key)`
and a proposal asked an identity question the schema had not answered.

For a `uris:file` it still has not. The key is a display name, the basename the file was found
under, and it is not unique. Each place a file lives in is unique, as `(resource, locator_key)`.
Nothing says two places hold one thing, so a file synced from two resources is two feeds, analyzed
twice, tagged twice, and counted twice.

What exists to build on:

- `feed_references.digest` is the SHA-256 of an original's bytes. `DigestReferencesJob` fills it
  every minute, twenty references at a time, and `Placement` copies it from the upload. It is
  indexed on `(tenant_id, digest)`.
- `Reference#note_version!` clears the digest when a sync reports a new version, so a digest always
  describes the current bytes or is empty.
- `Intake` already refuses a second upload of the same bytes when `unique` is set, under an
  advisory lock on `tenant:digest`, and only against resources the uploader can see.
- `Reference#move_to!` and `#split!` survived the removal. `splitReference` and the Split button on
  the item page still reach `split!`.
- Export already writes the copy it makes onto the source's feed through `Reference.record!`, so an
  exported file is one feed in two places today.

## Decisions

Each has the answer this plan assumes. Change one and the phase that depends on it changes.

- [ ] **A file's identity is its bytes.** Two originals with the same digest in one tenant are one
      thing and belong to one feed. The key stays a display name. Proposals and a review queue do
      not come back, because the same bytes are a fact rather than a judgement.
- [ ] **Joining is automatic, and splitting is the undo.** A reference split off by hand is marked
      apart and is not joined again until its bytes change.
- [ ] **Only places with the same owner join.** A tenant resource joins tenant resources, and a
      person's own resource joins only that person's resources. A feed never lists a personal place
      beside a shared one, so joining cannot tell others that a file sits in somebody's own
      Drive.
- [ ] **What survives.** The oldest feed with a settled analysis, or the oldest feed when none has
      one. The other feed's originals move onto it, its edges are added, its note is appended
      unless the survivor's already contains it, and the later of the two expiries is kept, with
      forever beating any date. Its analyses, derived references, children, and passages go with it,
      because they describe the same bytes the survivor already describes.
- [ ] **What does not join.** Empty files, whose digest is the same for every one of them. Feeds
      with a parent, which are part of something else. Gone references, and references on archived
      resources.
- [ ] **A changed file leaves at once.** When a sync reports a new version for a reference on a
      feed with other originals, the reference splits off before anything analyzes it, and takes
      a copy of the feed's tags and note. If its new digest matches something, the sweep joins it
      again. Waiting for the digest instead would analyze the feed from whichever original comes
      first, which may be the one that did not change.
- [ ] **Near duplicates are out of scope.** The same photo re-encoded, a PDF and the DOCX it came
      from, and two files with one name and different bytes are related, not identical. They are a
      later plan, and the likely shape is an edge found through embeddings.

## Phase 1: join the same bytes

- [ ] `Twins`, a model beside `Intake` and `Placement`, with `join!(digest)`. It takes the same
      advisory lock `Intake` takes, finds every eligible original with that digest, groups them by
      resource owner, and for each group with more than one feed moves every original onto the
      survivor and destroys the rest
- [ ] Recover `keep_note_from` from `6196e11^:app/models/feed.rb` for the note rule
- [ ] `Twins.sweep` finds digests held by more than one feed with a grouped query on the existing
      index, a bounded batch at a time. `DigestReferencesJob` calls it after each tenant's
      fingerprinting, so there is one job and one concurrency limit, and the first runs after
      deploy join what the catalog already holds
- [ ] Each join writes an audit event naming the survivor, the feeds it absorbed, and the digest
- [ ] Tests: two resources, one file, one feed after the sweep; three copies across two owners make
      two feeds; empty files and child feeds stay apart; a join never crosses tenants; edges, note,
      and expiry follow the rules above; the search index holds the survivor and not the absorbed
      feed; two sweeps at once join each digest once

## Phase 2: leave when the bytes change, stay apart when asked

- [ ] `feed_references.apart_at`. `split!` from `splitReference` sets it; `note_version!` clears it
      when the version changes; `Twins` skips references that have it
- [ ] `note_version!` on a reference whose feed has another original splits it into a new feed
      carrying the old feed's tags and note, and the sync analyzes the new feed as it would any
      changed file
- [ ] The item page's Split becomes "Keep apart", with a line saying the place was joined because
      the bytes are the same
- [ ] Tests: an edited copy leaves and is analyzed alone; a touched file with unchanged bytes
      leaves and is joined again; a kept-apart place stays apart through a sweep and joins again
      after an edit

## Phase 3: stop paying twice

A sync analyzes a new file straight away, before the digest sweep reaches it, so phase 1 joins
duplicates after they have already been analyzed.

- [ ] `AnalyzeFeedJob` fingerprints the original first when it has no digest, since the analysis
      downloads the bytes anyway, and calls `Twins.join!` before any step runs. If the feed is
      absorbed, the analysis finishes with one step naming the survivor and runs nothing else
- [ ] Holdings, the catalog counts, and export count feeds, so their numbers fall as
      joins land. Check each one reads right afterward
- [ ] Tests: a second resource holding an analyzed file adds a reference and no second analysis

## Phase 4: say so

- [ ] `docs/src/content/docs/concepts/references.mdx` gains a section on joining: the digest, the
      owner rule, what survives, leaving, and keeping apart. "Moving between feeds" stops saying
      that sync and export are the only things that move references
- [ ] `splitReference` gets a description, `ReferenceType` gains a described `digest` field, and `bin/rails docs:reference`
      regenerates the GraphQL reference
- [ ] `Reference.discover!` and `Intake` both create a feed per new place today. Say in the
      concept page that the join comes after, within a minute

## Verification

- The suite, with each phase's tests, plus these mutations each caught by a test: joining across
  owners, dropping the empty-file rule, joining a kept-apart reference, skipping the lock
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
