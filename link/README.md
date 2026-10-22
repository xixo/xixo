# xixo link

`xixo-link` runs on a machine and connects it to xixo. It enrolls with masks as
a client of its own, reports the machine's health, offers the folders its
configuration names, and reads files in those folders when xixo asks. xixo link
dials out to xixo, so the machine opens no port.

To link up a machine from the app, follow
[add a machine](https://docs.xixo.network/guides/add-a-machine/). This README
covers what runs on the machine.

## Installing

One command installs xixo link and links the machine up. Run it on the machine,
as the user who owns the shared folders:

```sh
curl -fsSL https://xixo.example.com/link.sh | sh -s -- ~/Documents ~/Desktop
```

The folders after `--` are the ones the machine shares. Leave them out to share
none yet, or to keep the folders of an earlier install. The script holds no
secret and reads nothing from standard input. It numbers its steps and prints
each one before it starts:

1. It downloads xixo link for the machine's system and processor from xixo,
   and checks it against the SHA-256 that xixo wrote into the script. It checks
   that each folder exists before anything asks for a password.
2. It runs `xixo-link install`, which installs the binary, writes the
   configuration, and installs the services, as [`install`](#commands)
   describes. On Linux that runs as root, and the script says before sudo asks
   for a password why it needs one.
3. On Debian or Ubuntu, it installs the programs that read PDFs, images, audio,
   video, and office documents with apt, unless they are installed already.
   apt writes to a log file. When apt fails, the script shows its last lines
   and the log's path, and goes on. macOS skips this step.
4. It runs `xixo-link up`, which waits for an administrator to approve the
   machine.
5. It runs `xixo-link start`, which starts the service or the launch agent, or
   restarts it on a rerun.

To link up a machine from your own computer instead, over ssh, see
[linking over ssh](#linking-over-ssh).

It ends with the summary that [`xixo-link status`](#commands) prints. Each
error starts with `Error:` and says what to do next. Color appears only on a
terminal, and never with `NO_COLOR` set.

Running the command again installs the build xixo ships and keeps the link and
its approval. After that, xixo link [updates itself](#updates).

## Configuration

`xixo-link setup` writes the configuration:

```json
{
  "xixo": "https://xixo.example.com",
  "issuer": "https://id.example.com",
  "folders": ["/srv/media", {"path": "/data/files", "writable": true}]
}
```

- Both addresses use https. Plain http works only for a loopback host such as
  `localhost`.
- Each folder is a clean absolute path, given alone for a folder xixo link only
  reads, or as `{"path", "writable"}`. No folder may lie inside another.
- The configuration is the only place the shared folders are named. xixo reads
  inside them and nowhere else, writes only inside the writable ones, and
  nothing xixo sends changes the list.

### What xixo may do

The machine describes itself when it links up and each time it connects, and
xixo plans what the machine does from that. An administrator approves the plan
and changes it on the machine's card. Two keys in the configuration set a limit
xixo cannot cross:

| Key | Allows | Left out |
| --- | --- | --- |
| `lend` | xixo reading the bytes of a shared file, for a download, a preview, or an extraction on another machine | allowed |
| `parts` | the parts named, out of `models` | all of them |

```json
{
  "xixo": "https://xixo.example.com",
  "issuer": "https://id.example.com",
  "folders": ["/srv/media"],
  "lend": false,
  "parts": []
}
```

Without lending, a file's bytes stay on the machine. xixo link still lists,
hashes, and extracts its own files, and sends xixo only what extraction makes.
An empty `parts` list runs none. A part name xixo link does not know stops it
from starting.

## Parts

A part is a program xixo link installs, runs, and checks for xixo, from a
recipe compiled into xixo link: the build's address and SHA-256 for each
system and processor, the command, and the health check. The first part is
`models`, which runs Ollama 0.40.6.

xixo sends a `parts` message with the parts it wants and their settings, on
every hello and whenever a machine's plan changes:

```json
{"parts": {"models": {"port": 11440, "models": ["qwen3:8b", "nomic-embed-text"], "context": 32768, "keep_alive": "30m"}}}
```

A part missing from the message is stopped. The message can name no build,
command, or path. `xixo-link part NAME` runs one part: it downloads the build,
checks it, unpacks it into `releases/<version>`, points `current` at it,
starts the program with `OLLAMA_HOST`, `OLLAMA_MODELS`,
`OLLAMA_CONTEXT_LENGTH`, and `OLLAMA_KEEP_ALIVE` from the settings, waits for
`GET /api/version`, pulls each model named, and writes its state to a status
file that xixo link reports in `health`. A version that fails its health check
within two minutes is rolled back to the `good` one. A download that stopped is
resumed.

On Linux, `xixo-link-part@.path` starts `xixo-link-part@NAME.service` when
xixo link writes `/run/xixo-link/parts/NAME`, and the service exits on its own
when that file goes away. The service runs as the system user
`xixo-link-part`, which the install makes, with its own state under
`/var/lib/xixo-link-part/NAME`, the GPU devices allowed, and the same limits
as `xixo-link.service` otherwise. On macOS, `xixo-link run` runs the
part as its child, as the user, under `~/Library/Application Support/xixo-link/parts/NAME`.

## Commands

`xixo-link` alone, or `xixo-link help`, lists the commands. Each command takes
`-h`.

| Command | Does |
| --- | --- |
| `xixo-link status` | Prints the machine's name in xixo, the address of its card, the version, whether the service runs, whether updates are on, each folder as read only or read and write, and the commands that show the service and its log. It needs no root. Run by an account that cannot read the keys, it says so and prints the rest. |
| `xixo-link setup --xixo URL --issuer URL [FOLDER ...]` | Writes the configuration, and prints nothing. Each folder must exist. End one with `:rw` to share it writable. A folder cannot hold a quotation mark, an apostrophe, a backslash, a colon, or a control character. Run again, it keeps every other key, and keeps the folders when none are given. |
| `xixo-link unit --template PATH [--user NAME]` | Prints the systemd unit for the folders the configuration shares. |
| `xixo-link up` | Links the machine up, as described in [linking up](#linking-up). A machine already linked prints "Already linked up as" and the name xixo shows for it. |
| `xixo-link describe [FOLDER[:rw] ...]` | Prints the machine's description as JSON, as `up` sends it: hostname, system, processor, the folders, and the details in [linking up](#linking-up). With folders named, it describes those and checks that each exists. Without, it describes the folders in the configuration, or none when there is no configuration. |
| `xixo-link enroll --token - [--name NAME]` | Reads an enrollment token from standard input, or from `XIXO_ENROLLMENT_TOKEN`, and registers xixo link's key with masks. `--name` defaults to the hostname. |
| `xixo-link run [--updates systemd\|self] [--revoked-status N]` | Connects to xixo and serves it until it is stopped. On SIGTERM or SIGINT, it waits at most five seconds for the requests it is answering, then exits. `--updates systemd` works only on Linux under systemd, and `--updates self` only on macOS. Without it, xixo link ignores updates. |
| `xixo-link update` | The Linux updater, run by `xixo-link-update.service`. |
| `xixo-link stage [--releases DIR]` | On macOS, installs its own binary and the mac reader beside it as an [update](#on-macos): a new folder under `releases/`, named by the start of its SHA-256, with `releases/current` pointing at it. The install command runs it on a rerun. |
| `xixo-link version` | Prints the version. |
| `xixo-link install --xixo URL --issuer URL --from PATH [--user NAME] [FOLDER[:rw] ...]` | Installs xixo link from the build at `--from`. On Linux, as root: it makes the `xixo-link-update` and `xixo-link-part` accounts when they are missing, installs the binary in `/usr/local/lib/xixo-link` owned by the updater, links it from `/usr/local/bin`, writes the configuration for the folders, fetches the service template and the updater and part units from xixo and writes them to `/etc/systemd/system`, makes the state directory for `--user`, and enables the services. On macOS, as the user: it installs the binary and the mac reader, as an update when the installed xixo link supervises itself, writes the configuration, and writes the launch agent. It starts nothing. |
| `xixo-link start` | Starts the service, or restarts it: `systemctl restart xixo-link` on Linux, as root, and the launch agent on macOS. |
| `xixo-link uninstall` | Stops xixo link and removes it, its configuration, its state, and its parts from the machine. It puts nothing away in xixo. Linux needs root. |
| `xixo-link join` | Reads `{"enrollment_token", "device_code", "name"}` as JSON on standard input, enrolls with masks as `enroll` does, and binds the machine with the device code as `up` does after approval. `xixo-link add` runs it over ssh. |
| `xixo-link linked` | Prints the machine's name, key, and card address in xixo as JSON, with the machine's own token. |
| `xixo-link login --xixo URL` | Signs you in to xixo from this computer, through the browser: it prints a link and a code, waits for your approval, and keeps the tokens in `~/.config/xixo-link/logins.json`, mode 0600. xixo starts the device grant with its own masks client, so the command line needs none. |
| `xixo-link add HOST [FOLDER[:rw] ...] [--user NAME] [--off LINES] [--xixo URL]` | Links up a machine over ssh, as [linking over ssh](#linking-over-ssh) describes. `--off` names plan lines to leave off, separated by commas. `--xixo` picks the xixo when you are signed in to more than one. |
| `xixo-link remove HOST [--xixo URL]` | Uninstalls xixo link on a machine over ssh and puts the machine away in xixo. |

Every command takes `--config PATH`, and `up`, `enroll`, `join`, `linked`, and
`run` take `--state DIR`. The defaults are in [files on the machine](#files-on-the-machine).

## Files on the machine

On Linux xixo link runs as a systemd service:

| Path | Holds |
| --- | --- |
| `/usr/local/lib/xixo-link/xixo-link` | The binary, owned by the `xixo-link-update` user, and `xixo-link.previous`, the one before the last update. |
| `/usr/local/bin/xixo-link` | A link to the binary. |
| `/etc/xixo-link/config.json` | The configuration. |
| `/var/lib/xixo-link/` | The state: `key.json` and `dpop.json`, the keys xixo link signs with, and `registration.json`, its masks client. |
| `/var/cache/xixo-link/work/` | Each extraction's private work folder, emptied when xixo link starts. |
| `/var/cache/xixo-link/digests.json` | The SHA-256 of each file of 1 MB or more that xixo link read, as in [hashing](#hashing). |
| `/etc/systemd/system/` | `xixo-link.service`, `xixo-link-update.service`, and `xixo-link-update.path`. |

On macOS xixo link runs as the user whose files it shares:

| Path | Holds |
| --- | --- |
| `~/Library/Application Support/xixo-link/bin/` | `xixo-link`, which the launch agent runs, and `xixo-mac-reader`. |
| `~/Library/Application Support/xixo-link/releases/` | The updates, one folder each. |
| `~/Library/Application Support/xixo-link/config.json` | The configuration. |
| `~/Library/Application Support/xixo-link/state/` | The keys, the registration, and the update files. |
| `~/Library/Caches/xixo-link/work/` | Each extraction's private work folder, emptied when xixo link starts. |
| `~/Library/Caches/xixo-link/digests.json` | The SHA-256 of each file of 1 MB or more that xixo link read, as in [hashing](#hashing). |
| `~/Library/LaunchAgents/network.xixo.link.plist` | The launch agent. |
| `~/Library/Logs/xixo-link.log` | What xixo link logs. |

The state directory is mode 0700 and every file in it is mode 0600. The keys
are made on the machine the first time xixo link enrolls and never leave it.

## The conversation with xixo

### Linking up

`xixo-link up` follows the OAuth device authorization grant (RFC 8628):

1. It makes its keys, then posts the machine's description to
   `<xixo>/link/requests`: the hostname, system, processor, and folders, and
   under `details` the account it runs as, the system's name, the hardware
   model, its kind (laptop, desktop, all-in-one, or server), whether it has a
   battery, its CPUs and memory, each GPU with its maker, model, memory, and
   driver version, the disk under each folder, its addresses, the readers it
   can run, and the model servers found on it. `xixo-link describe` prints the
   same.
2. It prints the link, such as `https://xixo.example.com/link/WDJB-MJHT`, on a
   line of its own, the code, and how long the request lasts. It says once a
   minute that it still waits.
3. It polls `<xixo>/link/requests/token` until an administrator approves or
   denies the machine, or the request runs out after ten minutes.
4. On approval, xixo hands it an enrollment token once, and xixo link enrolls
   with masks as `enroll` does.
5. It posts to `<xixo>/link` with its own token, and xixo links the new client
   to the machine.

xixo answers that post, and `GET <xixo>/link` with the machine's token, with
JSON: `{"name","key","url","updates"}`, the name xixo shows, the machine's
key, the address of the machine's card, and whether its updates are on. `up`
and `status` print the name. They drop control characters from it, and keep
`url` only when it starts with the xixo address in the configuration. An
enrolled machine that xixo answers 404 for asks for approval again.

### Linking over ssh

`xixo-link add` links up a machine from your own computer, with no approval
page, since you are already signed in:

```sh
xixo-link login --xixo https://xixo.example.com
xixo-link add media ~/Documents ~/Desktop-Backup:rw
xixo-link add old-mbp old-linux-1 old-linux-2
```

`login` asks xixo to start the device grant with xixo's own masks client, at
`POST <xixo>/link/cli/device`, prints the link and the code, and polls
`POST <xixo>/link/cli/token` until you approve in the browser. xixo answers
with the tokens masks issued to you, as Bearer tokens, and the command keeps
them in `~/.config/xixo-link/logins.json`, mode 0600, with the refresh token
that renews them. The command line holds no masks client and no secret of
xixo's. The tenant's masks client has to allow the device grant.

`add HOST` takes the host as ssh knows it, so your `~/.ssh/config`, keys, and
agent apply. xixo never holds an ssh key and never opens a connection to a
machine itself. The command numbers its steps:

1. `ssh HOST uname -sm`, to pick the build.
2. `GET <xixo>/link/builds` lists each build xixo serves with its SHA-256. The
   command downloads the one for the machine, checks it, and copies it over
   ssh to `~/.cache/xixo-link/xixo-link` on the machine.
3. `xixo-link describe FOLDERS` runs there, and the description comes back
   over ssh. Each folder is checked before anything asks for a password.
   `xixo-link linked` runs there too. When the machine is linked up with this
   xixo already, its key goes along in the next step, so it keeps its place.
4. `POST <xixo>/link/machines`, with your token, sends the description, the
   lines to leave off, and the key when there is one. xixo makes the plan,
   creates the request as approved, and answers with the plan, a one-time
   enrollment token, and the device code. The plan prints, one line each, as
   `on` or `off`.
5. `xixo-link install` runs there with the folders, over `ssh -t` and `sudo`
   on Linux, which asks for the machine's password. On macOS it runs as you.
6. `xixo-link join` runs there with the token and the device code on standard
   input. The key pair is made on the machine and never leaves it.
7. `xixo-link start` runs there, with `sudo` on Linux, and `xixo-link status`
   prints the result.

On Linux, `sudo -n true` runs there before step 2. When sudo asks for a
password and the command runs without a terminal, it stops there, before xixo
hears of the machine. When step 5 or 6 fails, the command asks xixo to put
the machine away again, so the next try starts clean.

`add` on a machine that is already linked installs the new build and keeps
its identity: xixo replaces the machine's client and keeps its key, name,
and operators. `remove HOST` runs `xixo-link linked` there to learn the
machine's key, runs `xixo-link uninstall` with `sudo` on Linux, and asks xixo
to put the machine away with `DELETE <xixo>/link/machines/KEY`. Both take an
administrator's sign-in.

### Signing in

xixo link is a masks client that signs in with `private_key_jwt` and holds
DPoP-bound tokens. `run` asks for a `client_credentials` token with the scope
`xixo:link` and the resource `<xixo>/mcp`, and opens a websocket to
`<xixo>/cable` with it. Each connection uses a fresh token. Before the token
expires, xixo link opens a new connection, and the old one finishes its
requests. A failed connection is retried after a pause that doubles from one
second up to one minute.

xixo link stops for good, with exit status 78, in two cases:

- masks answers `invalid_client` and says no client is registered with that
  client ID.
- xixo closes the connection with the reason `unknown_machine`, because no
  machine is enrolled as the client.

Every other failure, including masks refusing the client assertion because the
clock is wrong, is retried.

### Messages

xixo link speaks the Action Cable protocol on `LinkChannel`. It sends:

| Action | When |
| --- | --- |
| `hello` | Once connected: the version, system, folders, the description `up` sends, whether the configuration lends, and warnings. |
| `health` | After `hello`, and every minute: uptime, load, memory, and disk space. |
| `reply` | When a request is answered, with `ok` and a `result` or an `error`. |
| `chunk` | For each part of a file being read or made, base64 encoded, at most 256 KiB. |
| `changed` | When files in a shared folder change, so xixo looks at those paths at once. |

`warnings` holds sentences for the person who runs the machine, such as a shared
folder that does not exist or that macOS keeps from xixo link.

xixo link watches every directory under a shared folder, up to 16,384 on Linux and
4,096 on macOS. A folder with more is watched only in part, and a warning says
so. Raise the Linux limit with `sysctl fs.inotify.max_user_watches`. The
regular sync still finds anything a watch missed.

xixo sends `update`, as in [updates](#updates), and `cancel`, as in [waiting
and stopping](#waiting-and-stopping). It also sends requests, each naming a
verb:

| Verbs | Do |
| --- | --- |
| `list`, `read`, `hash`, `health` | List a shared folder, send a file's bytes, hash a file where it lies, and report health. |
| `extract`, `derive` | Read a shared file or an upload into steps and files. See [extraction](internal/extract/README.md). |
| `write`, `remove` | Place a file in a writable folder, and remove one whose size and SHA-256 xixo names. |
| `browse`, `find`, `peek`, `place`, `examine`, `model` | Answer MCP clients. |
| `relay` | Pass xixo's own requests on to a model server on the machine. |

A `list` names each file's path, size, modification time to the nanosecond, and
`file`, its device and inode. xixo tells a renamed file by that `file`.

A refused request is answered with `"ok": false` and an `error`. xixo link
refuses a folder its configuration does not name, a path outside the folder or
not in its shortest form, a symbolic link, and anything other than a regular
file. It never walks or reads these names: `.git`, `.hg`, `.svn`,
`node_modules`, `__pycache__`, `.venv`, `.tox`, `.Trash`, `.Trashes`,
`.Spotlight-V100`, `.fseventsd`, `.DS_Store`, `._*`, `Thumbs.db`,
`desktop.ini`, and its own `.xixo-*.part` files.

### Waiting and stopping

xixo link keeps two queues, so a slow extraction never holds up a quick request:

| Queue | Verbs | At once | Waiting |
| --- | --- | --- | --- |
| Extraction | `extract`, `derive`, `examine` | 2 | 16 |
| Everything else | `list`, `read`, `hash`, `health`, and the rest | 4 | 64 |

A request that finds its queue full is refused at once with an error that says
xixo link is busy. xixo then asks again later.

xixo gives each request a deadline, as `within`, in seconds. xixo link stops a
request when its deadline passes, whether the request is still waiting or
already running. When xixo gives up on a request before then, it sends
`{"cancel": "<request>"}`, and xixo link stops that request too. A stopped
request ends its programs, removes its work folder, sends no reply, and frees
its place in the queue. A cancel for a request xixo link does not hold changes
nothing.

### Hashing

xixo asks for the SHA-256 of a shared file with `hash`, and an extraction of a
shared file reports it too. xixo link remembers the SHA-256 of each file of 1 MB
or more it read, by the file's device, inode, size, modification time, and
change time. Every write changes the change time, so a rewritten file is always
read again, even when its size and modification time stay the same.

- An unchanged file is not read again, so a sync of a folder of films reads
  nothing.
- When several requests ask for one file at once, xixo link reads it once.
- A file that changes while xixo link reads it gets no SHA-256. xixo asks again
  later.
- On Linux, xixo link tells the system it is done with a file's pages after it
  hashed or copied the file, so a large film does not push other files out of
  memory.

xixo link keeps up to 100,000 SHA-256 values, the most recently used, and saves them
every minute and when it stops. Deleting `digests.json` is safe: xixo link
reads each file again the next time xixo asks.

## The service

`xixo-link.service` runs `xixo-link run --updates systemd` as the user who owns
the shared folders. systemd confines it:

- `/home`, `/root`, `/srv`, `/mnt`, `/media`, `/opt`, and `/var/lib` are empty
  for xixo link apart from its state directory. Each shared folder is mounted
  back, read-only or read-write, so a file outside them is missing even when
  xixo link's user could read it.
- It cannot write anywhere else, gain privileges, reach devices, or see other
  processes.
- Extraction programs run inside the same limits, with no sandbox of their own.
  They read a shared file where it lies, through the file xixo link opened, so
  they never follow a symbolic link out of the folder. A folder shared
  read-only cannot be written by them.
- It and its programs share `MemoryMax=2G`. A program the kernel stops for
  memory fails one extraction, and xixo link keeps running.
- It and its programs run at a low priority, so the machine's own work comes
  first: `Nice=10`, `CPUWeight=20`, `IOWeight=20`, and the lowest best-effort
  IO priority. On a Mac the launch agent runs it as a background process with
  low-priority IO.
- `TimeoutStopSec=15s` gives it 15 seconds to stop before systemd kills it.
- `RestartPreventExitStatus=78` keeps it stopped after the machine was
  unenrolled.

To raise the memory cap, run `sudo systemctl edit xixo-link` and set
`MemoryMax=` under `[Service]`. An install leaves that drop-in alone.

## Updates

xixo keeps every machine on the build of xixo link the server ships. When xixo
link says `hello`, xixo compares the SHA-256 of its binary, and on a Mac of its
mac reader, with that build. When they differ and the machine's updates are on,
xixo sends an `update` naming the version, the SHA-256 values, and the release
they belong to. xixo link then:

1. Downloads `release.json` and `release.sigstore.json` from the xixo address
   in its own configuration, following no redirect, so the message cannot send
   it to another host.
2. Checks the signature itself. It must be a build attestation from GitHub
   Actions, signed through Sigstore, for `xixo/xixo` on `main`, from `ci.yml` or
   `release.yml` on a GitHub-hosted runner, and it must cover `release.json`.
3. Checks that `release.json` lists the build xixo named, for this system and
   processor, and that its serial is not lower than the highest one this
   machine accepted.
4. Downloads the build and checks it against that SHA-256.
5. Runs the new binary's `version`, which must print the version xixo sent.
6. Swaps the new binary in and keeps the one before it.
7. Restarts into it. When the new binary does not connect within three
   minutes, the one before it comes back. Once it connects, the machine
   remembers the release's serial.

The server only mirrors the release. A server that was taken over cannot make a
machine install a build CI did not sign, or an older release than it has run.
Each build carries its own serial, so a machine that has never updated still
refuses anything older than what it was installed with. On macOS the serial is
kept once the supervisor sees the new release connect.
A failed update shows as a warning, and xixo link asks again six hours later.

The repository, workflows, and branch it trusts are compiled into xixo link,
so a fork builds its own. A machine running a build from a fork, or from a dev
stack, accepts unsigned builds only when its configuration says so:

```json
{
  "xixo": "https://xixo.localhost",
  "issuer": "https://xixo.localhost/id",
  "folders": ["/srv/media"],
  "releases": "unsigned"
}
```

### On Linux

xixo link must not be able to change the binary it runs, or a program that a
file took over during extraction could replace it. So the binary belongs to a
second system user, `xixo-link-update`, and a separate unit swaps it:

1. xixo link writes the request to `/run/xixo-link/update.json`.
2. `xixo-link-update.path` sees it and starts `xixo-link-update.service`, which
   runs `xixo-link update` as `xixo-link-update`.
3. The updater installs the new binary and keeps the old one as
   `xixo-link.previous`.
4. xixo link sees its binary change, finishes its work, and exits, and systemd
   starts the new one.
5. The updater waits three minutes for the new one to connect, and puts the old
   one back when it does not.

The updater keeps the highest serial it accepted in
`/usr/local/lib/xixo-link/serial`, where xixo link cannot write, and its
Sigstore trust files in `/usr/local/lib/xixo-link/trust`. It cannot see
`/var/lib/xixo-link`, where the keys are, and holds no capabilities. Nothing
runs as root after the install.

### On macOS

The launch agent runs `bin/xixo-link run --updates self`. That process never
changes itself. It runs the newest update from `releases/` as a child, and goes
back to the last good one when a new one does not connect within three minutes.
When launchd stops it, it gives the child 10 seconds to exit before it kills it.

macOS grants Full Disk Access to the binary the launch agent runs, so an update
keeps the access. Running the install command again keeps it too. When
`bin/xixo-link run -h` lists `-supervised`, the script leaves `bin/xixo-link`
in place and installs the new build with `xixo-link stage`, and the launch
agent tries it for three minutes like any update. Only a first install, or a
`bin/xixo-link` too old to run updates, replaces the binary, and then the
access has to be granted again.

## Beside the server

The `ghcr.io/xixo/xixo-link` image runs xixo link next to the xixo server. Its
entrypoint writes the configuration from the `XIXO_LINK_` variables and enrolls
with a token the server leaves in the handoff folder. It never updates itself,
and refuses `--updates`. It updates when its image does. When the machine is
unenrolled, it enrolls again. See
[self-hosting](https://docs.xixo.network/guides/self-hosting/).

## macOS

xixo link runs as a launch agent of the user whose files it shares, on Apple
silicon and Intel Macs.

### The launch agent

The launch agent runs under the label `network.xixo.link` when the user logs
in, at background priority. launchd restarts xixo link after it fails, at most
every 30 seconds, and leaves it stopped after the machine was unenrolled.

Restart xixo link after you change the configuration:

```sh
launchctl kickstart -k gui/$(id -u)/network.xixo.link
```

`launchctl print gui/$(id -u)/network.xixo.link` shows whether it is running
and its last exit status.

### Disk access

macOS guards `~/Documents`, `~/Desktop`, `~/Downloads`, iCloud Drive, and
removable and network volumes. A launch agent does not share the access granted
to Terminal, so until you grant it, xixo shows xixo link's warning that macOS
has not let it read the folder. When a shared folder needs it, the install
command lists these steps with the exact path, and opens the Finder and
**Full Disk Access** for you. A rerun keeps the access, and says so.

1. Open **System Settings**, then **Privacy & Security**, then **Full Disk
   Access**.
2. Drag `xixo-link` from `~/Library/Application Support/xixo-link/bin/` into
   the list. When the list holds an older `xixo-link`, remove it first.
3. Turn on the switch beside `xixo-link`.

xixo link checks every 15 seconds, and restarts itself once macOS lets it read
the folder. Full Disk Access lets xixo link's process read everything the user
can. xixo link's own path checks still keep xixo to the shared folders.

### The sandbox

On macOS every extraction program runs under `sandbox-exec`, with a profile xixo
link writes for that run. A shared file is read where it lies, with no copy.
The profile:

- denies everything by default, and allows reading the system and Homebrew
  folders and the work folder
- allows reading the one shared file the extraction reads, and nothing else in
  the shared folders
- allows writing only inside the work folder
- allows no network

The mac reader may also use the GPU and the Neural Engine, which Vision needs
for text recognition. LibreOffice may also reach the window server and the
pasteboard, which it starts even when headless.

The sandbox has limits. macOS refuses the data size limit, so a program's
memory is not capped. A program that crashes can open a crash report dialog.
Apple marks `sandbox-exec` deprecated, though it works on current macOS. When
`sandbox-exec` is missing, xixo link runs no extraction program and warns.

### What a Mac reads

With the mac reader beside xixo link, a Mac reads every kind of file xixo sends
to a machine with what macOS ships. Homebrew is optional. Each extractor uses
the first of its programs that the Mac has:

| Extractor | Programs, in order |
| --- | --- |
| `pdf` | the mac reader, then poppler and tesseract |
| `image` | the mac reader, then vips, exiftool, tesseract, and libraw |
| `media` | ffmpeg, then the mac reader |
| `doc` | `textutil`, then LibreOffice and poppler |

Every other extractor reads files in Go. A Mac without Homebrew has these gaps:

- `metadata` for a type outside images, PDFs, media, and documents needs
  exiftool.
- Matroska, WebM, Ogg, and AVI need ffmpeg.
- A legacy `.xls` spreadsheet needs LibreOffice.

To read more, install exiftool and ffmpeg, then restart xixo link so `hello`
lists the extractors they enable:

```sh
brew install exiftool ffmpeg
```

### Logs

```sh
tail -f ~/Library/Logs/xixo-link.log
```

## Uninstalling

Remove the machine in xixo first, so masks forgets its client. Then, on Linux:

```sh
sudo systemctl disable --now xixo-link xixo-link-update.path
sudo rm -rf /etc/systemd/system/xixo-link.service /etc/systemd/system/xixo-link.service.d
sudo rm -f /etc/systemd/system/xixo-link-update.service /etc/systemd/system/xixo-link-update.path
sudo rm -rf /usr/local/bin/xixo-link /usr/local/lib/xixo-link
sudo rm -rf /etc/xixo-link /var/lib/xixo-link /var/cache/xixo-link
sudo userdel xixo-link-update
sudo systemctl daemon-reload
```

On macOS:

```sh
launchctl bootout gui/$(id -u)/network.xixo.link
rm ~/Library/LaunchAgents/network.xixo.link.plist
rm -r ~/Library/Application\ Support/xixo-link ~/Library/Caches/xixo-link
rm ~/Library/Logs/xixo-link.log
```

Then remove `xixo-link` from **Full Disk Access**.

## Building

xixo link is one static binary for Linux and macOS on amd64 and arm64:

```sh
for os in linux darwin; do
  for arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=0.1.0" -o xixo-link-$os-$arch .
  done
done
```

The Go linker signs `darwin/arm64` binaries ad hoc, also on Linux, so they run
on Apple silicon without a separate signing step. The xixo image builds all
four into `/opt/xixo-link`, with the systemd units, the plist, and a `version`
file the server reads. A release build takes its version from
`.release-please-manifest.json`. A build from main adds the commit after it,
as `0.2.0+1a2b3c4`, through the `XIXO_COMMIT` build argument. The updater
orders versions by the three numbers and ignores what follows the `+`, so a
machine on `0.2.0` takes `0.2.0+1a2b3c4`, and takes `0.2.1` after it.

The mac reader, `xixo-mac-reader`, is a Swift program that reads PDFs, images,
audio, and video with the frameworks macOS ships. It builds only on a Mac with
the Xcode command line tools, as one binary for Apple silicon and Intel:

```sh
make -C macos
```

Each release and each push to main builds it on a macOS runner and hands it to
the image build. A release also attaches it to the GitHub release:

```sh
docker build --build-context mac-reader=link/macos/build .
```

An image built without that context holds no mac reader.

`go test ./...` runs the tests. On macOS they also run the installed extraction
programs and the mac reader under the sandbox. `XIXO_SANDBOX_OFFICE=1 go test
./internal/extract -run LibreOffice` also runs LibreOffice under the sandbox,
which is left out by default because a crash there opens a dialog.
