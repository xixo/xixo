# xixo-agent

`xixo-agent` runs on a machine and connects it to xixo. It enrolls with masks
as a client of its own, reports the machine's health, offers the folders its
configuration names, and reads files in those folders when xixo asks. The
agent dials out to xixo, so the machine opens no port.

## Building

The agent is one static binary. It builds for Linux and macOS on amd64 and
arm64:

```sh
for os in linux darwin; do
  for arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=0.1.0" -o xixo-agent-$os-$arch .
  done
done
```

The Go linker signs `darwin/arm64` binaries ad hoc, also when it builds them on
Linux, so they run on Apple silicon without a separate signing step.

The xixo image builds all four into `/opt/xixo-agent`, next to
`xixo-agent.service` and `xixo-agent.plist`.

`go test ./...` runs the tests. On macOS the tests also run real extraction
programs under the sandbox when they are installed.
`XIXO_SANDBOX_OFFICE=1 go test ./internal/extract -run LibreOffice` converts a
document with LibreOffice under the sandbox, which is left out by default
because a crash there opens a crash report dialog.

## Files on the machine

On Linux the agent runs as a system service:

| Path | Holds |
| --- | --- |
| `/usr/local/bin/xixo-agent` | The binary. |
| `/etc/xixo-agent/config.json` | Where xixo and masks are, and the folders the agent shares. |
| `/var/lib/xixo-agent/key.json` | The private key the agent signs its client assertions with. |
| `/var/lib/xixo-agent/dpop.json` | The private key the agent proves its tokens with. |
| `/var/lib/xixo-agent/registration.json` | The client masks registered for the agent, and its registration access token. |
| `/etc/systemd/system/xixo-agent.service` | The unit, from `xixo-agent.service` with `@USER@` and `@FOLDERS@` replaced. |

On macOS the agent runs as the user whose files it shares:

| Path | Holds |
| --- | --- |
| `~/Library/Application Support/xixo-agent/bin/xixo-agent` | The binary. |
| `~/Library/Application Support/xixo-agent/config.json` | The configuration. |
| `~/Library/Application Support/xixo-agent/state/` | `key.json`, `dpop.json`, and `registration.json`. |
| `~/Library/Caches/xixo-agent/work/` | Each extraction's private work folder, emptied when the agent starts. |
| `~/Library/LaunchAgents/network.xixo.agent.plist` | The launch agent, from `xixo-agent.plist` with `@HOME@` replaced. |
| `~/Library/Logs/xixo-agent.log` | What the agent logs. |

The state directory is mode 0700 and every file in it is mode 0600. The keys
are made on the machine the first time the agent enrolls and never leave it.

The configuration looks like this:

```json
{
  "xixo": "https://xixo.example.com",
  "issuer": "https://id.example.com",
  "folders": ["/srv/media", {"path": "/data/files", "writable": true}],
  "lend": false,
  "extracts_for_others": false,
  "extract_unsandboxed": false
}
```

Both addresses use https. Plain http is accepted only for a loopback host such
as `localhost` or a `.localhost` name. Each folder is a clean absolute path,
given alone for a folder the agent only reads, or as `{"path", "writable"}`. The
configuration on the machine is the only place the shared folders are named:
xixo can read inside them and nowhere else, writes only inside the writable
ones, and nothing xixo sends changes the list.

`lend` lets xixo read the bytes of a shared file, for a download, a preview, or
an extraction on another agent. Left false, a file's bytes stay on the machine:
the agent still lists, hashes, and extracts its own files, and sends xixo only
what extraction makes. `extracts_for_others` lets the agent read uploads and
files from other places that xixo sends it to extract. Both default to false.

`extract_unsandboxed` matters on macOS only. The agent runs every extraction
program under `sandbox-exec`, and when `sandbox-exec` is missing it runs none
of them and offers only the extractors that need no program. Set to true, the
agent runs the programs without the sandbox instead. It defaults to false.

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

`enroll` and `run` take `--config PATH` and `--state DIR`. They default to
`/etc/xixo-agent/config.json` and `/var/lib/xixo-agent` on Linux, and to
`~/Library/Application Support/xixo-agent/config.json` and
`~/Library/Application Support/xixo-agent/state` on macOS.

`run` takes `--revoked-status N`, the exit status when the machine was
unenrolled. It defaults to 78.

On macOS, `run` adds `/opt/homebrew/bin`, `/usr/local/bin`, and
`/Applications/LibreOffice.app/Contents/MacOS` to the end of `PATH`, so it finds
programs installed with Homebrew. It finds `tailscale` on `PATH` or at
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

## Signing in

The agent is a masks client that authenticates with `private_key_jwt` and
holds DPoP-bound tokens. `run` asks for a `client_credentials` token with the
scope `xixo:agent` and the resource `<xixo>/mcp`. It opens a websocket to
`<xixo>/cable` with the token in `Authorization: DPoP <token>`, a DPoP proof
for `GET <xixo>/cable` in the `DPoP` header, and xixo's origin in `Origin`.
When xixo answers with a `DPoP-Nonce`, the agent dials once more with a proof
naming that nonce.

Each connection uses a fresh token. Two minutes before the token expires, or
halfway through its remaining life when that is sooner, the agent opens a new
connection with a new token. The old connection stops taking requests and
finishes the ones it is answering until the token expires, which is when xixo
closes it. A request still running at that moment fails. A client withdrawn
in masks loses its connection within one token lifetime. A failed connection
is retried after a jittered pause that doubles from one second up to one
minute.

## The conversation with xixo

The agent speaks the Action Cable protocol and subscribes to
`{"channel":"AgentChannel"}`. Everything it sends is a `message` command whose
`data` is a JSON object with an `action`:

| Action | Fields | When |
| --- | --- | --- |
| `hello` | `version`, `os`, `arch`, `hostname`, `folders`, `writable`, `services`, `extractors`, `lend`, `extracts_for_others`, `warnings` | Once the subscription is confirmed. |
| `health` | `uptime`, `load`, `memory`, `disks`, `warnings` | After `hello`, and every minute. |
| `reply` | `request`, `ok`, `result` or `error` | When a request is answered. |
| `chunk` | `request`, `of`, `seq`, `data` | For each part of a file being read or made. |

`services` lists the model servers listening on the machine's loopback
address: `{"kind":"ollama","port":11434,"address":"100.64.0.7"}`, and
`lmstudio` on port 1234. `address` is the machine's tailnet IPv4 address when
`tailscale ip -4` answers, and empty otherwise.

`extractors` names the extractors whose programs are on the machine, so xixo
sends each file to an agent that can read it.

`writable` names the shared folders the configuration marks writable.

`warnings` is a list of sentences for the person who runs the machine, empty
when nothing is wrong. The agent checks every shared folder each time it sends
`hello` or `health`, and adds a sentence for one it cannot list: a folder that
does not exist, or one the agent may not read. On macOS a folder that privacy
protection keeps from the agent reads "macOS has not let xixo-agent read
/Users/you/Documents; allow it in System Settings → Privacy & Security → Full
Disk Access, then restart the agent". A missing `sandbox-exec` adds a sentence
too.

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
| `write` | `folder`, `path`, `upload`, `size`, `replace` | `{"path","size","modified_at"}` |

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
to overwrite an existing file.

`hash` reads the file where it lies and answers with its SHA-256 in hex and its
size, sending none of its bytes.

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
type, size, and that id. The reply also carries the source's `sha256` and
`size`, computed as the agent read it. [internal/extract/README.md](internal/extract/README.md)
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

## macOS

On macOS the agent runs as a launch agent of the user whose files it shares,
so it reads that user's files with that user's permissions. It runs on Apple
silicon and on Intel Macs.

### Installing

1. Get `xixo-agent-darwin-arm64` for Apple silicon or `xixo-agent-darwin-amd64`
   for an Intel Mac, and `xixo-agent.plist`. Put the binary in place:

   ```sh
   mkdir -p ~/Library/Application\ Support/xixo-agent/bin
   install -m 0755 xixo-agent-darwin-arm64 ~/Library/Application\ Support/xixo-agent/bin/xixo-agent
   ```

2. A browser marks a downloaded file as quarantined, and macOS then refuses to
   run a binary that Apple has not notarized. Remove the mark. The command
   reports "No such xattr" when the file has none, which is fine.

   ```sh
   xattr -d com.apple.quarantine ~/Library/Application\ Support/xixo-agent/bin/xixo-agent
   ```

   The binary carries an ad hoc signature from the Go linker. `codesign -dv`
   on the binary shows it, and `codesign -f -s -` signs it ad hoc again after
   anything has changed it.

3. Write `~/Library/Application Support/xixo-agent/config.json`, as described
   in [files on the machine](#files-on-the-machine), and give it mode 0600:

   ```json
   {
     "xixo": "https://xixo.example.com",
     "issuer": "https://id.example.com",
     "folders": ["/Users/you/Documents", "/Users/you/Desktop"]
   }
   ```

4. Enroll the machine with the token xixo shows, pasted on standard input and
   ended with Control-D:

   ```sh
   ~/Library/Application\ Support/xixo-agent/bin/xixo-agent enroll --token -
   ```

5. Install the launch agent and start it:

   ```sh
   sed "s|@HOME@|$HOME|g" xixo-agent.plist > ~/Library/LaunchAgents/network.xixo.agent.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/network.xixo.agent.plist
   ```

6. Give the agent access to the protected folders it shares, as described in
   [disk access](#disk-access).

### The launch agent

`xixo-agent.plist` runs `xixo-agent run` under the label `network.xixo.agent`
when the user logs in, at background priority with low-priority disk access,
and with a umask of 0077. It sets `PATH` to the system folders, Homebrew's
folders, and LibreOffice's.

launchd cannot keep a job alive for every exit status but one, so the plist
runs the agent with `--revoked-status 0` and sets `KeepAlive` to
`SuccessfulExit` false. launchd restarts the agent after it fails or crashes,
at most every 30 seconds, and leaves it stopped after the machine was
unenrolled. A machine that was never enrolled fails and is restarted every 30
seconds. After an unenrollment the agent starts again at the next login, is
refused, and stops again.

```sh
launchctl kickstart -k gui/$(id -u)/network.xixo.agent
launchctl print gui/$(id -u)/network.xixo.agent
```

`kickstart -k` restarts the agent, which it needs after disk access is granted
and after the configuration changes. `print` shows whether it is running and
its last exit status.

### Disk access

macOS privacy protection guards `~/Documents`, `~/Desktop`, `~/Downloads`,
iCloud Drive, and removable and network volumes. A program needs the user's
permission to read them, and a launch agent does not share the permission
granted to Terminal. `xixo-agent run` started in Terminal reads `~/Documents`
when Terminal may, while the same binary under launchd is refused. xixo then
shows the agent's warning that macOS has not let it read the folder.

To grant access:

1. Open **System Settings**, then **Privacy & Security**, then **Full Disk
   Access**.
2. Click **+**, press Command-Shift-G, enter
   `~/Library/Application Support/xixo-agent/bin/xixo-agent`, and click
   **Open**.
3. Turn on the switch beside `xixo-agent`.
4. Restart the agent with `launchctl kickstart -k gui/$(id -u)/network.xixo.agent`.

macOS can also ask on its own the first time the agent reaches a protected
folder. Allowing that adds the agent under **Files and Folders**, which grants
only the folders asked for. Full Disk Access lets the agent's process read
everything the user can, including mail and message databases. The agent's own
path checks still keep xixo to the configured folders.

macOS records the permission against the binary's code signature. An ad hoc
signature changes with every build, so a new version of the binary is a new
program to macOS. After an upgrade, remove the old `xixo-agent` entry, add the
binary again, and restart the agent.

### The sandbox

On Linux, systemd confines the whole agent. On macOS the agent runs as the
user, with the network it needs to reach masks and xixo, and every extraction
program runs under `sandbox-exec` with a profile the agent writes for that
run. The agent copies a shared file into the extraction's work folder before
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

`soffice` gets more, because LibreOffice starts the macOS application
frameworks even when headless. It may also read `/Applications/LibreOffice.app`,
reach the launch services, window server, pasteboard, disk arbitration, power
management, privacy, and system configuration services, and create its
`OSL_PIPE_*` socket in `/tmp`.

The sandbox has limits:

- A program can see that the work folder's parent folders exist, though it
  cannot list them.
- A program can read any file under the system and Homebrew folders.
- LibreOffice can reach the pasteboard, so a document that took it over could
  read the clipboard. With no network, what it reads can only reach xixo in the
  extraction's output.
- macOS refuses the data size limit that Linux sets with `ulimit -d`, so a
  program's memory is not capped on macOS. The file size limit, the deadline,
  and the work folder's size budget hold.
- A program that crashes can open a crash report dialog on the user's screen.
- Apple marks `sandbox-exec` deprecated. It works on current macOS, which uses
  the same profile language for its own services.

When `sandbox-exec` is missing, the agent runs no extraction program and warns
in `hello` and `health`, unless the configuration sets `extract_unsandboxed`.

### Programs for extraction

The extractors use programs from Homebrew:

```sh
brew install exiftool poppler tesseract ffmpeg vips libraw
```

LibreOffice is needed only for `.doc`, `.docx`, `.odt`, and older spreadsheet
formats. Without it, the agent leaves the `doc` extractor out of `extractors`
and xixo sends those files elsewhere.

```sh
brew install --cask libreoffice
```

Restart the agent after installing programs, so `hello` lists the extractors
they enable.

### Logs

The agent logs to `~/Library/Logs/xixo-agent.log`:

```sh
tail -f ~/Library/Logs/xixo-agent.log
```

### Uninstalling

```sh
launchctl bootout gui/$(id -u)/network.xixo.agent
rm ~/Library/LaunchAgents/network.xixo.agent.plist
rm -r ~/Library/Application\ Support/xixo-agent ~/Library/Caches/xixo-agent
rm ~/Library/Logs/xixo-agent.log
```

Remove `xixo-agent` from **Full Disk Access**, and remove the machine in xixo
so masks forgets its client.
