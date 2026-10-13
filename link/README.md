# xixo-link

`xixo-link` runs on a machine and connects it to xixo. It enrolls with masks
as a client of its own, reports the machine's health, offers the folders its
configuration names, and reads files in those folders when xixo asks. xixo
link dials out to xixo, so the machine opens no port.

## Building

xixo link is one static binary. It builds for Linux and macOS on amd64 and
arm64:

```sh
for os in linux darwin; do
  for arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=0.1.0" -o xixo-link-$os-$arch .
  done
done
```

The Go linker signs `darwin/arm64` binaries ad hoc, also when it builds them on
Linux, so they run on Apple silicon without a separate signing step.

The xixo image builds all four into `/opt/xixo-link`, next to
`xixo-link.service`, `xixo-link-update.service`, `xixo-link-update.path`, and
`xixo-link.plist`.

On macOS xixo link also uses the mac reader, `xixo-mac-reader`, a small Swift
program that reads PDFs, images, audio, and video with the frameworks macOS
ships. It builds only on a Mac with the Xcode command line tools, as one
binary for Apple silicon and Intel:

```sh
make -C macos
```

The binary lands in `macos/build/xixo-mac-reader`, signed ad hoc. The xixo
image cannot build it, so each release builds it on a macOS runner, attaches it
to the release on GitHub, and hands it to the image build as the `mac-reader`
build context:

```sh
docker build --build-context mac-reader=link/macos/build .
```

The image keeps it at `/opt/xixo-link/mac/xixo-mac-reader`, and xixo serves it
at `/link/download/xixo-mac-reader`. An image built without the context holds no
mac reader. See [what a Mac reads](#what-a-mac-reads) for what it does.

`go test ./...` runs the tests. On macOS the tests also run real extraction
programs under the sandbox when they are installed, and, once `make -C macos`
has built the mac reader, read PDFs, images, documents, audio, and video under
the sandbox with a `PATH` that holds only the system folders, the way a Mac
without Homebrew does.
`XIXO_SANDBOX_OFFICE=1 go test ./internal/extract -run LibreOffice` converts a
document with LibreOffice under the sandbox, which is left out by default
because a crash there opens a crash report dialog.

## Files on the machine

On Linux xixo link runs as a system service:

| Path | Holds |
| --- | --- |
| `/usr/local/lib/xixo-link/xixo-link` | The binary, owned by the `xixo-link-update` user. |
| `/usr/local/lib/xixo-link/xixo-link.previous` | The binary before the last update. |
| `/usr/local/bin/xixo-link` | A link to the binary. |
| `/etc/xixo-link/config.json` | Where xixo and masks are, and the folders xixo link shares. |
| `/var/lib/xixo-link/key.json` | The private key xixo link signs its client assertions with. |
| `/var/lib/xixo-link/dpop.json` | The private key xixo link proves its tokens with. |
| `/var/lib/xixo-link/registration.json` | The client masks registered for xixo link, and its registration access token. |
| `/var/cache/xixo-link/work/` | Each extraction's private work folder, emptied when xixo link starts. |
| `/etc/systemd/system/xixo-link.service` | The unit, from `xixo-link.service` with `@USER@` and `@FOLDERS@` replaced. |
| `/etc/systemd/system/xixo-link-update.service` | The updater, which runs as `xixo-link-update`. |
| `/etc/systemd/system/xixo-link-update.path` | Starts the updater when xixo link asks for an update. |
| `/run/xixo-link/` | `update.json`, the update xixo link asks for, and `running.json`, the build that last connected. |
| `/run/xixo-link-update/result.json` | How the last update went. |

On macOS xixo link runs as the user whose files it shares:

| Path | Holds |
| --- | --- |
| `~/Library/Application Support/xixo-link/bin/xixo-link` | The binary the launch agent runs, which runs the newest update. |
| `~/Library/Application Support/xixo-link/releases/` | The updates, one folder each, with `current` and `good` links to two of them. |
| `~/Library/Application Support/xixo-link/config.json` | The configuration. |
| `~/Library/Application Support/xixo-link/state/` | `key.json`, `dpop.json`, and `registration.json`, and the update files `update.json`, `running.json`, and `result.json`. |
| `~/Library/Caches/xixo-link/work/` | Each extraction's private work folder, emptied when xixo link starts. |
| `~/Library/LaunchAgents/network.xixo.link.plist` | The launch agent, from `xixo-link.plist` with `@HOME@` replaced. |
| `~/Library/Logs/xixo-link.log` | What xixo link logs. |

The state directory is mode 0700 and every file in it is mode 0600. The keys
are made on the machine the first time xixo link enrolls and never leave it.

The configuration looks like this:

```json
{
  "xixo": "https://xixo.example.com",
  "issuer": "https://id.example.com",
  "folders": ["/srv/media", {"path": "/data/files", "writable": true}]
}
```

`xixo-link setup` writes it. Both addresses use https. Plain http is accepted
only for a loopback host such as `localhost` or a `.localhost` name. Each
folder is a clean absolute path, given alone for a folder xixo link only reads,
or as `{"path", "writable"}`. The configuration on the machine is the only
place the shared folders are named: xixo can read inside them and nowhere
else, writes only inside the writable ones, and nothing xixo sends changes the
list.

### What xixo may do

xixo decides what the machine does for it, and the administrator changes that
on the machine's card at any time. xixo sends the choice over the cable, in
the [`settings` message](#the-conversation-with-xixo), and xixo link applies it
at once. Until the first `settings` message arrives, xixo link lends nothing,
reads nothing for other machines, and offers no tools.

The configuration can set a ceiling. xixo link does what xixo asks only when
the configuration also allows it, so xixo can narrow what the configuration
allows and never widen it:

| Key | Allows | Left out |
| --- | --- | --- |
| `lend` | xixo reading the bytes of a shared file, for a download, a preview, or an extraction on another machine | allowed |
| `extracts_for_others` | reading uploads and files from other places that xixo sends it to extract | allowed |
| `tools` | the tools named, out of `browse`, `search`, `read`, `write`, `extract`, and `models` | all of them |

```json
{
  "xixo": "https://xixo.example.com",
  "issuer": "https://id.example.com",
  "folders": ["/srv/media"],
  "lend": false,
  "tools": ["browse", "search"]
}
```

Without lending, a file's bytes stay on the machine: xixo link still lists,
hashes, and extracts its own files, and sends xixo only what extraction makes.

Each tool is a verb below that xixo link answers only when it is allowed both
by the configuration and by xixo. An empty `tools` list allows none. `read`
still needs lending, and `write` a writable folder; the `write` verb that
places xixo's own files needs the `write` tool too, and so does `remove`. A tool name xixo link does
not know stops it from starting. The container beside the server sets these
keys from `XIXO_LINK_LEND`, `XIXO_LINK_EXTRACTS_FOR_OTHERS`, and
`XIXO_LINK_TOOLS` when they are set, and leaves them out otherwise.

`extract_unsandboxed` matters on macOS only. xixo link runs every extraction
program under `sandbox-exec`, and when `sandbox-exec` is missing it runs none
of them and offers only the extractors that need no program. Set to true, xixo
link runs the programs without the sandbox instead. It defaults to false.

## Commands

`xixo-link setup --xixo URL --issuer URL [FOLDER ...]` writes the
configuration. Each folder is an absolute path to a folder that exists; end
one with `:rw` to share it writable. A folder cannot hold a quotation mark, an
apostrophe, a backslash, a colon, or a control character, and cannot lie
inside another shared folder. Run again, `setup` keeps every other key in the
configuration, and keeps the folders when none are given. It writes the file
with mode 0644 on Linux, where the service's user reads a file root owns, and
0600 on macOS.

`xixo-link unit --template PATH [--user NAME]` prints the systemd unit: the
template `xixo-link.service` with `@USER@` replaced by the user, this one by
default, and `@FOLDERS@` by the folders the configuration shares, as described
in [the service](#the-service).

`xixo-link up` links the machine up, as described in
[linking up](#linking-up). When the machine is already linked, it says so and
does nothing else.

`xixo-link enroll --token - [--name NAME]` reads an enrollment token from
standard input, registers xixo link's public key with masks, and saves the
registration. `--token` also takes the token itself, and the
`XIXO_ENROLLMENT_TOKEN` variable is read when the flag is empty. Standard input
keeps the token out of the process list. `--name` is the name masks shows for
the machine, and defaults to the hostname. The container beside the server
enrolls this way, with a token the server leaves it.

`xixo-link run` connects to xixo and serves it until it is stopped.
`--updates systemd` or `--updates self` lets it update itself, as described in
[updates](#updates). Without the flag it ignores xixo's updates.

`xixo-link update` is the Linux updater. It reads the request in
`/run/xixo-link/update.json`, installs the build it names in place of its own
binary, and waits for the new one to connect. `--requests DIR` and
`--results DIR` move the two folders.

`xixo-link version` prints the version.

The commands take `--config PATH`, and `up`, `enroll`, and `run` take
`--state DIR`. They default to `/etc/xixo-link/config.json` and
`/var/lib/xixo-link` on Linux, and to
`~/Library/Application Support/xixo-link/config.json` and
`~/Library/Application Support/xixo-link/state` on macOS.

`run` takes `--revoked-status N`, the exit status when the machine was
unenrolled. It defaults to 78.

On macOS, `run` adds `/opt/homebrew/bin`, `/usr/local/bin`, and
`/Applications/LibreOffice.app/Contents/MacOS` to the end of `PATH`, so it finds
programs installed with Homebrew. It finds `tailscale` on `PATH` or at
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

## Installing

One command installs xixo link and links the machine up. Run it on the
machine, as the user who owns the shared folders:

```sh
curl -fsSL https://xixo.example.com/link.sh | sh -s -- ~/Documents ~/Desktop
```

The folders after `--` are the ones the machine shares. Leave them out to
share none yet, or to keep the folders of an earlier install. The script needs
no secret, and puts none in the process list or in shell history. It:

1. Finds the system and the processor.
2. Downloads xixo link from xixo and checks it against the SHA-256 that xixo
   wrote into the script.
3. On Debian or Ubuntu, installs the programs that read PDFs, images, audio,
   video, and office documents with apt. On macOS, fetches the mac reader from
   the release and checks it against the `.sha256` published beside it.
4. Writes the configuration with `xixo-link setup`, and the systemd unit with
   `xixo-link unit` or the launch agent.
5. Runs `xixo-link up`, which waits for an administrator to approve the
   machine.
6. Starts the service.

Running the command again installs the build xixo ships and keeps the link.
After that, xixo link [updates itself](#updates).

## Linking up

`xixo-link up` follows the shape of the OAuth device authorization grant
(RFC 8628):

1. It makes its keys, then posts to `<xixo>/link/requests` the machine's
   hostname, system, processor, and folders as JSON:
   `{"hostname","os","arch","folders","writable"}`.
2. xixo answers with `device_code`, `user_code`, `verification_uri`,
   `verification_uri_complete`, `expires_in`, and `interval`. xixo link prints
   "Open https://xixo.example.com/link/WDJB-MJHT to approve this machine" and
   the code.
3. It posts `device_code` to `<xixo>/link/requests/token` every `interval`
   seconds. xixo answers 400 with the error `authorization_pending` while it
   waits, `slow_down` when xixo link asks too often, which adds five seconds,
   `access_denied` when an administrator denied the machine, and
   `expired_token` when the request ran out, about ten minutes after it began.
4. Once an administrator approves the machine, xixo answers with an
   `enrollment_token`, once. xixo link enrolls with masks with it, as `enroll`
   does.
5. It posts `device_code` to `<xixo>/link` with its own DPoP-bound token, and
   xixo links the new client to the machine.

The `device_code` stays with xixo link and is never shown. The `user_code` is
what the administrator sees, to match the machine they approve with the one
asking.

Before it asks, `up` checks a machine that is enrolled already with
`GET <xixo>/link` and its own token. xixo answers 200 with the machine's name
when it knows the client, and 404 when it does not, in which case `up` asks
again.

## Signing in

xixo link is a masks client that authenticates with `private_key_jwt` and
holds DPoP-bound tokens. `run` asks for a `client_credentials` token with the
scope `xixo:link` and the resource `<xixo>/mcp`. It opens a websocket to
`<xixo>/cable` with the token in `Authorization: DPoP <token>`, a DPoP proof
for `GET <xixo>/cable` in the `DPoP` header, and xixo's origin in `Origin`.
When xixo answers with a `DPoP-Nonce`, xixo link dials once more with a proof
naming that nonce.

Each connection uses a fresh token. Two minutes before the token expires, or
halfway through its remaining life when that is sooner, xixo link opens a new
connection with a new token. The old connection stops taking requests and
finishes the ones it is answering until the token expires, which is when xixo
closes it. A request still running at that moment fails. A client withdrawn
in masks loses its connection within one token lifetime. A failed connection
is retried after a jittered pause that doubles from one second up to one
minute.

## The conversation with xixo

xixo link speaks the Action Cable protocol and subscribes to
`{"channel":"LinkChannel"}`. Everything it sends is a `message` command whose
`data` is a JSON object with an `action`:

| Action | Fields | When |
| --- | --- | --- |
| `hello` | `version`, `os`, `arch`, `hostname`, `folders`, `writable`, `services`, `extractors`, `lend`, `extracts_for_others`, `warnings`, `tools`, `sha256`, `mac_reader`, `updates` | Once the subscription is confirmed. |
| `health` | `uptime`, `load`, `memory`, `disks`, `warnings` | After `hello`, and every minute. |
| `reply` | `request`, `ok`, `result` or `error` | When a request is answered. |
| `chunk` | `request`, `of`, `seq`, `data` | For each part of a file being read or made. |
| `changed` | `folder`, `paths`, `overflow` | When files in a shared folder change, two seconds after the last change and at most ten seconds after the first. |

xixo sends `{"settings":{"tools","lend","extracts_for_others"}}` as a broadcast
on the subscription right after `hello`, and again whenever an administrator
changes what the machine may do. xixo link does what both the settings and its
configuration allow, as described in [what xixo may do](#what-xixo-may-do).

xixo also sends `{"update":{"version","sha256","downgrade","mac_reader"}}` right
after `hello` when xixo link can update itself and runs another build, as
described in [updates](#updates).

`sha256` is the SHA-256 of xixo link's own binary, and `mac_reader` that of the
mac reader beside it, when there is one. `updates` is `systemd` or `self` when
xixo link can update itself, and left out otherwise.

`services` lists the model servers listening on the machine's loopback
address: `{"kind":"ollama","port":11434,"address":"100.64.0.7"}`, and
`lmstudio` on port 1234. `address` is the machine's tailnet IPv4 address when
`tailscale ip -4` answers, and empty otherwise.

`extractors` names the extractors whose programs are on the machine, so xixo
sends each file to a machine that can read it.

`writable` names the shared folders the configuration marks writable.

`tools`, `lend`, and `extracts_for_others` are the configuration's ceiling:
the tools it allows, in a fixed order, and whether it allows lending and
reading for others. xixo combines them with its own settings.

`warnings` is a list of sentences for the person who runs the machine, empty
when nothing is wrong. xixo link checks every shared folder each time it sends
`hello` or `health`, and adds a sentence for one it cannot list: a folder that
does not exist, or one xixo link may not read. On macOS a folder that privacy
protection keeps from xixo link reads "macOS has not let xixo-link read
/Users/you/Documents; allow it in System Settings → Privacy & Security → Full
Disk Access, then restart xixo link". A missing `sandbox-exec` adds a sentence
too.

`changed` names the paths in one shared folder that were written, created,
moved, or removed, relative to the folder, so xixo looks at those paths again
at once instead of waiting for its next walk; the walk still runs and catches
anything missed. A new or removed directory is named itself, and xixo looks
at everything under it. One message holds at most 256 paths; more than that,
or changes the system dropped, come as `overflow: true` with no paths, and
xixo walks the whole folder. Names that are never shared are never told.

On Linux xixo link watches every directory under a shared folder with
inotify, up to 16,384 directories and the system's own
`fs.inotify.max_user_watches`. On macOS it watches each directory with kqueue,
which needs an open file for each one, so it stops at 4,096; kqueue tells it
when a directory's entries change, and it compares the directory with what it
saw before to name the files. A file rewritten in place on macOS, without a
new name or a rename, is not seen until the next walk. A folder with more
directories than that is watched only in part, and a warning says so; raise
the Linux limit with `sysctl fs.inotify.max_user_watches`. Watching needs no
dependency beyond `golang.org/x/sys`, which xixo link already uses.

`health` holds `uptime` in seconds, `load` as the 1, 5, and 15 minute
averages, `memory` as `{"total","available"}` in bytes, and `disks` as
`[{"path","total","free"}]` in bytes for `/` and each shared folder. Linux
reads these from `/proc`. macOS reads them from `sysctl`: `kern.boottime`,
`vm.loadavg`, and `hw.memsize`, with `available` taken as the share of memory
in `kern.memorystatus_level`, the free percentage `memory_pressure` prints.

xixo sends a request as the `message` of a broadcast on the subscription:

```json
{"request": "6c1d0a3e-0d5e-4f8e-9a51-7f1b6b1c2d3e", "verb": "list", "args": {"folder": "/srv/media"}}
```

| Verb | Args | Result |
| --- | --- | --- |
| `health` | none | The fields of a `health` message. |
| `list` | `folder`, `cursor`, `prefix`, `limit`, `skip` | `{"entries":[{"path","size","modified_at"}],"cursor"}` |
| `read` | `folder`, `path` | `chunk` messages, then `{"size"}` |
| `hash` | `folder`, `path` | `{"sha256","size"}` |
| `extract` | `source`, `size`, `mime`, `filename`, `skip`, `settings` | each made file's `chunk` messages, then the steps and the list of files |
| `derive` | as `extract` | the thumbnail and preview alone |
| `write` | `folder`, `path`, `upload`, `size`, `replace`, `modified_at` | `{"path","size","modified_at"}` |
| `remove` | `folder`, `path`, `sha256`, `size`, `prune` | `{"path","size","pruned"}` |
| `browse` | `folder`, `prefix`, `cursor`, `limit` | as `list`, 200 files at most |
| `find` | `query`, `folder`, `limit` | `{"matches":[{"folder","path","size","modified_at"}],"visited","complete"}` |
| `peek` | `folder`, `path`, `limit` | `{"data","size","total"}` |
| `place` | as `write` | as `write` |
| `examine` | as `extract`, with a shared file as `source` | the steps, and none of the files |
| `model` | `kind`, `model`, `messages`, `max_tokens` | `{"kind","model","text","truncated","finish_reason"}` |

`list` walks the folder depth first in name order and returns at most `limit`
regular files, 500 at most. Paths are relative to the folder and
`modified_at` is RFC 3339 in UTC. A `cursor` in the result means more files
follow, and passing it back resumes after the last path returned. `prefix`
keeps the paths that start with it, and `skip` adds name patterns to the ones
that are always skipped.

`read` sends the file as `chunk` messages of at most 256 KiB, base64 encoded,
numbered from 0, followed by a reply holding the number of bytes sent.

`write` fetches the upload from xixo the way `extract` does, then places it at
`path` inside a writable folder. It writes a temporary `.xixo-*.part` file
beside the target, syncs it, and moves it into place, so a reader never sees a
partial file. It creates the folders on the way inside the shared folder only.
It refuses a read-only or unshared folder, a link anywhere on the path, a name
a walk skips, and bytes that do not match `size`. Without `replace` it refuses
to overwrite an existing file. With `modified_at`, an RFC 3339 time, the file
gets that modification time before it is moved into place.

`remove` deletes a file inside a writable folder. It reads the file where it
lies, and removes it only when its size and SHA-256 match `size` and `sha256`
and it did not change while it was read. xixo can therefore remove only bytes
it has already seen somewhere else, which is how a move works: xixo copies a
file, has the other machine hash the copy, and asks for the original to be
removed with that hash. `remove` refuses everything `write` refuses. With
`prune`, it then removes each folder above the file that the removal left
empty, up to the shared folder and never the shared folder itself. A folder
that holds only `.DS_Store`, `Thumbs.db`, or `desktop.ini` counts as empty, and
those files go with it. `pruned` lists the folders it removed.

`hash` reads the file where it lies and answers with its SHA-256 in hex and its
size, sending none of its bytes.

`browse`, `find`, `peek`, `place`, `examine`, and `model` answer MCP clients,
and each is refused unless the configuration names its tool: `browse`, `search`,
`read`, `write`, `extract`, and `models`. They refuse an argument they do not
know.

`find` walks every shared folder, or the one named, and keeps the paths that
hold `query`, ignoring case. It stops at `limit` matches, 100 at most, after
20,000 files, or after ten seconds, and `complete` says whether it saw every
file.

`peek` needs `lend` too. It answers with up to `limit` bytes of the file, 256
KiB at most, base64 encoded in `data`, with `total` the file's size.

`place` is `write` for a file of at most 1 MiB.

`examine` runs the extractors on a shared file and answers with the steps and
the source's `sha256` and `size`. It refuses an upload, sends none of the files
the extractors make, and drops any step larger than 256 KiB, saying so in
`dropped`. It stops after two minutes.

`model` asks the model server of `kind`, `ollama` or `lmstudio`, one question.
It posts an OpenAI-compatible chat completion to
`http://127.0.0.1:<port>/v1/chat/completions`, on port 11434 for Ollama and
1234 for LM Studio, dialing that address whatever the request says and following
no redirect. `messages` holds 1 to 32 messages from `system`, `user`, or
`assistant`, 64 KiB in all. Without `model` it asks `/v1/models` and uses the
first. `max_tokens` defaults to 1024 and stops at 4096. The answer's text is cut
at 64 KiB, with `truncated` set, and the whole exchange stops after 90 seconds.

An upload is a file xixo holds for xixo link to read. `extract` names it as
`{"upload": id}` with its `size`, and xixo link fetches
`<xixo>/link/uploads/<id>` once over HTTPS with its token and a fresh DPoP
proof. The address is built from the configured xixo address and the id, which
must be a UUID, so the token never goes anywhere else, and a redirect is not
followed. The body goes into the extraction's private work directory, at most
4 GiB, and must be exactly `size` bytes. xixo serves an upload once, to the
machine it was staged for, within 15 minutes.

`extract` reads an upload (`{"upload": id}`) or a shared file
(`{"folder", "path"}`) and answers with its steps. Each file it makes, such as a
thumbnail, is sent first as `chunk` messages under a new id, with `of` naming
the `extract` request, and the reply lists the files with their role, name,
type, size, and that id. The reply also carries the source's `sha256` and
`size`, computed as xixo link read it. [internal/extract/README.md](internal/extract/README.md)
describes every step.

A refused request is answered with `"ok": false` and an `error`. xixo link
refuses a folder its configuration does not name, a path that is absolute,
not in its shortest form, or outside the folder, a path through a symbolic
link, a path through a skipped name, and anything other than a regular file.

xixo link never walks or reads symbolic links or these names: `.git`, `.hg`,
`.svn`, `node_modules`, `__pycache__`, `.venv`, `.tox`, `.Trash`, `.Trashes`,
`.Spotlight-V100`, `.fseventsd`, `.DS_Store`, `._*`, `Thumbs.db`, and
`desktop.ini`. It answers up to four requests at once.

## The service

`xixo-link.service` runs `xixo-link run --updates systemd` as the user named in place of
`@USER@`, which is the user who owns the shared folders. systemd creates the
state directory for that user, restarts xixo link when it stops, and keeps it
from writing anywhere else, gaining privileges, or reaching devices. xixo link
also runs in its own user namespace, sees no other process in `/proc`, and makes
only the system calls an ordinary service makes.

`xixo-link unit` writes a `BindReadOnlyPaths=` line in place of `@FOLDERS@`, one
quoted entry per shared folder, and a `BindPaths=` line for the writable ones.
`/home`, `/root`, `/srv`, `/mnt`, `/media`, `/opt`, and `/var/lib` are empty
for xixo link apart from its state directory, and each shared folder is
mounted back, read-only or read-write, so a file outside them is missing even
when xixo link's user could read it. This holds behind xixo link's own path
checks. `ReadWritePaths=` would not work for a writable folder: it reopens a
path xixo link can already see, and these are hidden until a bind puts them
back.

The unit also:

- caps xixo link and its programs at `MemoryMax=2G`, with `OOMPolicy=continue`
  so a program the kernel stops for memory fails one extraction and xixo link
  keeps running. `sudo systemctl edit xixo-link` sets a higher cap in a
  drop-in that an install leaves alone
- starts after `time-sync.target`. A clock that is wrong anyway makes masks
  refuse xixo link's assertion, which xixo link retries, so it does not stop
- gives xixo link `/var/cache/xixo-link` as its cache, read through
  `CACHE_DIRECTORY`, so extraction works on disk on a machine whose `/tmp` is
  a tmpfs
- allows `setrlimit`, which `@resources` denies, so the limit script can lower
  a program's limits on a libc that calls it directly. glibc uses
  `prlimit64`, which `@system-service` allows

Each extraction program on Linux gets its work folder as `HOME` as well as
`TMPDIR`. Under `MemoryDenyWriteExecute=yes`, LibreOffice maps its code through
a file it makes in `$HOME`, and aborts when `$HOME` is the read-only mount
point a shared folder under `/home` leaves behind. A per-run home also keeps a
file such as `~/.ExifTool_config` from outliving the extraction.

When masks answers `invalid_client`, or xixo closes the connection with the
reason `unknown_machine` because no machine is enrolled as the client, the
machine was unenrolled, so xixo link exits with status 78 and the unit's
`RestartPreventExitStatus=78` keeps it stopped. Any other failure to reach
masks or xixo, including xixo turning a token away for another reason, is
retried with backoff.

Removing xixo link from a machine is done on the machine:

```sh
sudo systemctl disable --now xixo-link xixo-link-update.path
sudo rm -rf /etc/systemd/system/xixo-link.service /etc/systemd/system/xixo-link.service.d
sudo rm -f /etc/systemd/system/xixo-link-update.service /etc/systemd/system/xixo-link-update.path
sudo rm -rf /usr/local/bin/xixo-link /usr/local/lib/xixo-link
sudo rm -rf /etc/xixo-link /var/lib/xixo-link /var/cache/xixo-link
sudo userdel xixo-link-update
sudo systemctl daemon-reload
```

## Updates

xixo keeps every machine on the build of xixo link the server ships. The
server knows that build's version and the SHA-256 of each system's binary. When
xixo link says `hello`, xixo compares the `sha256` it sent, and on a Mac the
`mac_reader` too, with the build it ships. When they differ, the machine's
updates are on, and xixo link said it can update itself, xixo sends:

```json
{"update": {"version": "0.3.0", "sha256": "…", "downgrade": false, "mac_reader": "…"}}
```

`mac_reader` is there only for a Mac, when xixo holds a mac reader.
`downgrade` is true when the version is older than the one xixo link runs.
xixo link refuses an older version without it, so only a server that ships an
older build, such as after a rollback, moves a machine back.

Each system then:

1. Downloads `<xixo>/link/download/xixo-link-<os>-<arch>`, and on a Mac
   `<xixo>/link/download/xixo-mac-reader`, from the xixo address in its own
   config, following no redirect. The message names no address, so it cannot
   send xixo link to another host.
2. Checks each download against the SHA-256 in the message, and deletes one
   that does not match.
3. Runs the new binary's `version`, which must print the version xixo sent.
4. Swaps the new binary in with a rename on the same file system, and keeps
   the one before it.
5. Restarts into it. When the new binary does not connect to xixo within three
   minutes, or stops before it does, the one before it comes back.

xixo link asks for a given build once. When the update failed, it says so in
its `warnings` ten minutes later, and asks again six hours after it first asked.

A build older than updates does not know `--updates` or `--supervised`. When
a server rolled back that far sends it, it stops at once, and the machine goes
back to the build it ran.

An administrator turns updates off for one machine on its card. The container
beside the server never updates itself. It runs without `--updates`, so it
says nothing about updating in `hello` and ignores an `update` message. Its
image is pinned like the server's, and updates when the image does.

### On Linux

xixo link runs as the user who owns the shared folders. It must not be able to
change the binary it runs, or a program that a file took over during
extraction could replace xixo link for good. So the binary lives in
`/usr/local/lib/xixo-link`, which belongs to a second system user,
`xixo-link-update`, and a separate unit swaps it:

1. xixo link writes the request to `/run/xixo-link/update.json`, mode 0644, and
   keeps serving.
2. `xixo-link-update.path` sees the file change and starts
   `xixo-link-update.service`, which runs `xixo-link update` as
   `xixo-link-update`.
3. The updater downloads and checks the build, keeps the old binary as
   `xixo-link.previous`, and renames the new one into place.
4. xixo link checks its binary every five seconds. When the file changes, it
   finishes its work and exits with status 75, and systemd starts the new one.
5. The new xixo link writes `/run/xixo-link/running.json` once it connects.
   The updater waits for it for three minutes, and puts `xixo-link.previous`
   back when it does not come. The waiting xixo link sees its binary change
   again and restarts into the old one.
6. The updater writes how it went to `/run/xixo-link-update/result.json`.

The updater runs under the same systemd confinement as xixo link. It writes
only `/usr/local/lib/xixo-link` and its own runtime folder, cannot see
`/var/lib/xixo-link`, where the keys are, and holds no capabilities. It reads
the request it is given and nothing else xixo link writes. A request can only
name a build that xixo serves, since the updater downloads from the address in
`/etc/xixo-link/config.json`, which root owns. It handles each request once,
so a request that failed is not tried again until xixo link writes a new one.
Nothing runs as root after the install.

The other layout keeps the binary in xixo link's own state folder, where xixo
link replaces it itself. That needs no second user or unit, and lets any
program xixo link runs replace xixo link. xixo link takes the second user
instead.

### On macOS

The launch agent runs `bin/xixo-link run --updates self`. That process runs the
newest update as a child and never changes itself:

1. The child downloads and checks the build into a new folder under
   `releases/`, named by the start of its SHA-256, with the mac reader beside
   it. When xixo holds no mac reader, it copies the one it has.
2. It points `releases/current` at the folder, and exits with status 75.
3. The parent starts `releases/current/xixo-link`. When the child writes
   `state/running.json` within three minutes, the parent points
   `releases/good` at the folder. When it does not, or stops first, the parent
   points `current` back at `good`, or at nothing, and starts that one.

macOS grants Full Disk Access to a binary by its code signature, which changes
with every build. The child runs under the parent, and macOS checks the
parent, so an update keeps the access. Running the install command again
replaces `bin/xixo-link`, and the access has to be granted again.

## macOS

On macOS xixo link runs as a launch agent of the user whose files it shares,
so it reads that user's files with that user's permissions. It runs on Apple
silicon and on Intel Macs.

### Installing

The [install command](#installing) works on a Mac too:

```sh
curl -fsSL https://xixo.example.com/link.sh | sh -s -- ~/Documents ~/Desktop
```

It puts `xixo-link` and `xixo-mac-reader` side by side in
`~/Library/Application Support/xixo-link/bin`, removes earlier updates, writes the configuration,
installs the launch agent from `xixo-link.plist` with `@HOME@` replaced, links
up, and starts the launch agent. xixo link looks for the mac reader beside its
own binary first, then on `PATH`. Without it, a Mac reads PDFs, images, audio,
and video only with the Homebrew programs in [what a Mac reads](#what-a-mac-reads).

curl leaves no quarantine mark, so macOS runs the binaries without asking. The
binary carries an ad hoc signature from the Go linker. `codesign -dv` on the
binary shows it, and `codesign -f -s -` signs it ad hoc again after anything
has changed it.

A folder in Documents, Desktop, Downloads, or iCloud Drive also needs
[disk access](#disk-access).

### The launch agent

`xixo-link.plist` runs `xixo-link run --updates self` under the label `network.xixo.link`
when the user logs in, at background priority with low-priority disk access,
and with a umask of 0077. It sets `PATH` to the system folders, Homebrew's
folders, and LibreOffice's.

launchd cannot keep a job alive for every exit status but one, so the plist
runs xixo link with `--revoked-status 0` and sets `KeepAlive` to
`SuccessfulExit` false. launchd restarts xixo link after it fails or crashes,
at most every 30 seconds, and leaves it stopped after the machine was
unenrolled. A machine that was never enrolled fails and is restarted every 30
seconds. After an unenrollment xixo link starts again at the next login, is
refused, and stops again.

```sh
launchctl kickstart -k gui/$(id -u)/network.xixo.link
launchctl print gui/$(id -u)/network.xixo.link
```

`kickstart -k` restarts xixo link, which it needs after disk access is granted
and after the configuration changes. `print` shows whether it is running and
its last exit status.

### Disk access

macOS privacy protection guards `~/Documents`, `~/Desktop`, `~/Downloads`,
iCloud Drive, and removable and network volumes. A program needs the user's
permission to read them, and a launch agent does not share the permission
granted to Terminal. `xixo-link run` started in Terminal reads `~/Documents`
when Terminal may, while the same binary under launchd is refused. xixo then
shows xixo link's warning that macOS has not let it read the folder.

To grant access:

1. Open **System Settings**, then **Privacy & Security**, then **Full Disk
   Access**.
2. Click **+**, press Command-Shift-G, enter
   `~/Library/Application Support/xixo-link/bin/xixo-link`, and click
   **Open**.
3. Turn on the switch beside `xixo-link`.
4. Restart xixo link with `launchctl kickstart -k gui/$(id -u)/network.xixo.link`.

macOS can also ask on its own the first time xixo link reaches a protected
folder. Allowing that adds xixo link under **Files and Folders**, which grants
only the folders asked for. Full Disk Access lets xixo link's process read
everything the user can, including mail and message databases. xixo link's own
path checks still keep xixo to the configured folders.

macOS records the permission against the binary's code signature. An ad hoc
signature changes with every build, so a new version of the binary is a new
program to macOS. An [update](#on-macos) keeps the permission, since the binary
the launch agent runs stays the same. After running the install command again,
remove the old `xixo-link` entry, add the binary again, and restart xixo link.

### The sandbox

On Linux, systemd confines the whole of xixo link. On macOS xixo link runs as the
user, with the network it needs to reach masks and xixo, and every extraction
program runs under `sandbox-exec` with a profile xixo link writes for that
run. xixo link copies a shared file into the extraction's work folder before
any program sees it, so the programs never read the shared folders.

The profile:

- denies everything by default and imports Apple's `system.sb`, which allows
  system libraries and the basic system services
- allows reading `/bin`, `/sbin`, `/usr`, `/opt/homebrew`, `/usr/local`,
  `/private/etc`, the system font folders, `/Library/Perl`, and the work folder
- hides `/opt/homebrew/var`, `/opt/homebrew/etc`, `/usr/local/var`, and
  `/usr/local/etc`, apart from their `fonts` folders, since Homebrew keeps
  databases and service configuration there
- allows writing only inside the work folder
- allows no network

The mac reader gets more, because Vision runs its text recognition on the
GPU and the Neural Engine, and AVFoundation looks up the system's audio codecs.
It may also:

- read its own binary, list the folder that holds it (Vision looks there for
  resources), and see that the folders above it exist
- open the IOSurface, Apple GPU, and Neural Engine user clients
  (`IOSurfaceRootUserClient`, `AGXDeviceUserClient`, and
  `H11ANEInDirectPathClient`)
- reach `com.apple.appleneuralengine` and
  `com.apple.audio.AudioComponentRegistrar`, the registry of audio codecs

It reaches no network, no audio device, no window server, and no pasteboard.
Vision without the GPU client reads no text and reports no error, so the tests
check that a known receipt reads under the sandbox.

`textutil` runs under the plain profile.

`soffice` gets more, because LibreOffice starts the macOS application
frameworks even when headless. It may also read `/Applications/LibreOffice.app`,
reach the launch services, window server, pasteboard, disk arbitration, power
management, privacy, and system configuration services, and create its
`OSL_PIPE_*` socket in `/tmp`.

The sandbox has limits:

- A program can see that the work folder's parent folders exist, though it
  cannot list them.
- A program can read any file under the system and Homebrew folders.
- The mac reader can open the GPU and Neural Engine drivers, which gives a file
  that took it over more of the kernel to reach than the other programs have.
- The profile names the Apple GPU's driver. An Intel Mac's GPU has another
  driver, which the profile does not open, and the mac reader's OCR there is
  untested.
- LibreOffice can reach the pasteboard, so a document that took it over could
  read the clipboard. With no network, what it reads can only reach xixo in the
  extraction's output.
- macOS refuses the data size limit that Linux sets with `ulimit -d`, so a
  program's memory is not capped on macOS. The file size limit, the deadline,
  and the work folder's size budget hold.
- A program that crashes can open a crash report dialog on the user's screen.
- Apple marks `sandbox-exec` deprecated. It works on current macOS, which uses
  the same profile language for its own services.

When `sandbox-exec` is missing, xixo link runs no extraction program and warns
in `hello` and `health`, unless the configuration sets `extract_unsandboxed`.

### What a Mac reads

A Mac reads every kind of file xixo sends to a machine with what macOS ships,
once the mac reader sits beside xixo link. Homebrew is optional. Each
extractor uses the program listed first that the Mac has:

| Extractor | Programs, in order | What a Mac without Homebrew reads |
|---|---|---|
| `pdf` | the mac reader, then poppler and tesseract | the text of each page with PDFKit, with pages separated by form feeds and the PDF's bookmarks as an `outline`; a page with too little text is rendered at 200 dpi and read by Vision |
| `image` | the mac reader, then vips, exiftool, tesseract, and libraw | dimensions, deviation, frames, and location with ImageIO, which reads HEIC, WebP, TIFF, and camera raw files; text with Vision |
| `media` | ffmpeg, then the mac reader | the probe, the signal, the 16 kHz WAV for transcription, and video frames with AVFoundation |
| `doc` | `textutil`, then LibreOffice and poppler | `.doc`, `.docx`, `.odt`, `.rtf`, and `.webarchive`; headings and tables from a `.docx` or `.odt` itself, else `textutil`'s plain text; `info` holds the title and author |
| `epub`, `xlsx`, `calendar`, `pkpass`, `email`, `contact`, `data`, `text`, `fallback` | none | everything, since these read files in Go |

The two steps every extractor gets also work without Homebrew. `metadata`
uses exiftool when it is installed, and otherwise the mac reader for images,
PDFs, audio, and video and `textutil -info` for documents. Thumbnails and
previews come from the mac reader, except that video and audio use ffmpeg when
it is installed.

The mac reader goes first for PDFs and images because Vision reads scans and
photographs better than tesseract does. ffmpeg goes first for media because it
opens more containers and measures loudness to the EBU R128 standard, which the
mac reader follows closely. `textutil` goes first for documents because it
needs no exception in the sandbox, while LibreOffice needs the window server
and the pasteboard.

Some programs macOS ships are left out. `mdls` reads the Spotlight index,
which never covers the extraction's work folder. `sips` writes through the
user's temporary folder whatever `TMPDIR` says, which the sandbox refuses, so
the mac reader draws images with ImageIO instead. `qlmanage` hands the file to
Quick Look's own services outside xixo link's sandbox. AVFoundation decodes
every format `afconvert` reads, so the mac reader makes the WAV itself.

A Mac without Homebrew has these gaps:

- `metadata` for an epub, a spreadsheet, an archive, or any other type outside
  images, PDFs, media, and documents fails with "reading this kind of file's
  metadata needs exiftool, which this Mac lacks"
- AVFoundation opens MP4, MOV, M4A, MP3, WAV, AIFF, CAF, and FLAC; Matroska,
  WebM, Ogg, and AVI need ffmpeg
- a legacy `.xls` spreadsheet needs LibreOffice
- `info` for a document carries no page count
- without the mac reader, a recording's waveform needs ffmpeg and a page
  capture's thumbnail needs vips

Homebrew installs the programs that read more:

```sh
brew install exiftool ffmpeg
```

exiftool reads metadata from every type, and ffmpeg opens every container.
poppler, tesseract, vips, libraw, and LibreOffice are used when the mac reader
is missing:

```sh
brew install poppler tesseract vips libraw
brew install --cask libreoffice
```

Restart xixo link after installing programs, so `hello` lists the extractors
they enable.

### Logs

xixo link logs to `~/Library/Logs/xixo-link.log`:

```sh
tail -f ~/Library/Logs/xixo-link.log
```

### Uninstalling

```sh
launchctl bootout gui/$(id -u)/network.xixo.link
rm ~/Library/LaunchAgents/network.xixo.link.plist
rm -r ~/Library/Application\ Support/xixo-link ~/Library/Caches/xixo-link
rm ~/Library/Logs/xixo-link.log
```

Remove `xixo-link` from **Full Disk Access**, and remove the machine in xixo
so masks forgets its client.
