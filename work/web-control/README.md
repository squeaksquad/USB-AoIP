# `usb16x16-web` — control service, and `usb16x16-apply` — its privileged half

The backend the web UI talks to. It serves `work/web-ui` and a small JSON API
describing the running stack: service states, bridge telemetry, PTP, AoIP
streams, network and thermal state, the journal, durable presets, and, since
2026-09-11, the live service profile and one staged operation: a switch
between accepted profiles (step 5 of `work/web-ui/README.md`, "staged Apply").

The web service itself still changes no device state. Apply is two halves
with a file between them:

- `usb16x16-web` (unprivileged, `NoNewPrivileges`) validates the request
  against its cached snapshot and writes **one file**,
  `~/usb-16x16-work/web-apply/request.json`, atomically. That is its only
  write outside the preset store.
- `usb16x16-apply` (root, run by `usb16x16-apply.path` when that file
  changes) re-validates against the live `/etc/usb16x16/aes67.conf`, refuses
  anything but a profile whose block says `STATUS=accepted`, refuses a stale
  page (the browser names the profile it believes is live), then runs
  `systemctl stop`, the supervisor's own `switch-profile`, `systemctl start`,
  waits for `STAGE running`, checks the bridge line (fresh, zero direction
  restarts), the RECOVER count and the `DSP loaded` / `DSP engaged` lines the
  profile calls for, holds 30 s, and rolls back to the previous profile
  through the same steps if any of that fails. Every step lands in
  `web-apply/current.json` as it happens and the final state in
  `web-apply/receipts/<id>.json`. It never edits a block, installs a preset,
  or touches the gadget, daemon or module.

A profile switch restarts the AES67 service: audio stops for about a minute
and the latency level is drawn afresh (the record's standing rule). The UI
says so before it asks, and the applier's receipt records the bridge's start
lines so the draw can be read afterwards.

## User presets (browser-compiled)

Since 2026-09-11 evening the page can send its own draft. The compiler is the
verified one in `work/dsp-compiler`, served beside the UI as
`web-ui/compiler/*.mjs` (symlinks in the repo, copies on the Pi), so the
browser compiles the draft to the bridge artifact and posts the text. The Pi
never trusts it: the applier recomputes the hash, parses the artifact with the
bridge loader's own bounds, requires every biquad section to be stable and the
total to stay at or under 308 (the count the loaded soak passed), then loads it
through the bridge's own code (`usb16x16-dsp-offline --bench 1`, installed by
this package from the dsp-verify build of the accepted source), installs it as
`/etc/usb16x16/dsp/user-<slug>.dsp` (root, 0644), writes a profile block
`user-<slug>` whose transport fields are dsp-direct's copied verbatim plus the
preset path and hash, has the supervisor's parser validate the whole file on a
temporary copy, replaces the live conf atomically, and only then runs the
switch. Such a block is `STATUS=experimental` (the supervisor's own word: it
refuses to switch to anything but accepted or experimental) and is a user
preset by its `user-<slug>` name; it is never `accepted`: the guards stand in
for a soak and the panel says so. Eight user presets at most; a re-apply of the
same name replaces its block and file; a slug may not be another's dash-prefix.

```
POST   /api/apply/preset            {"name", "artifact", "artifactSha256"?, "expectedProfile"} -> 202 {id, profile, slug, replacing}
DELETE /api/apply/preset/<slug>     queue removal of a user preset that is not live -> 202 {id}
```

Receipts for a preset carry `kind: "preset"`, `stats` (biquads, internal
channels, max delay) and `loaderLine` (what the runner printed). The supervisor
accepts `user-<slug>.dsp` paths since its 2026-09-11 change; the applier
refuses to install anything if the runner is missing.

## Apply API and states

```
GET  /api/apply/status           {current, pending, inFlight}: the applier's current.json plus whether a request waits
POST /api/apply/profile          {"profile": NAME, "expectedProfile": LIVE|null} -> 202 {id} | 400 | 409 | 503
```

`409` when the page's expected profile is not the live one, when the target is
already live, or when an operation is queued or running; `503` when
`usb16x16-apply.path` is not active (Apply not installed or disarmed). The
health snapshot carries `profile` (`selected`, `profiles[]` with status,
description, measured, cover, preset) and `control.apply` (`available`,
`reason`, `scope`).

States, in order: `validating`, `stopping`, `switching`, `starting`,
`verifying`, `settling`, then `done`; or `rolling-back` then `rolled-back`,
`failed` (the rollback failed too: read the receipt and the journal,
`journalctl -u usb16x16-apply -u usb16x16-aes67`), or `refused` (nothing was
touched). A `current.json` left in a non-terminal state for ten minutes is
treated as abandoned so a new request is not blocked for ever; the applier's
unit times out at 480 s.

Tests: `python3 -m unittest work/web-control/test_apply.py work/web-control/test_web.py`
(the applier's state machine against a scripted stack, the artifact parser on
the shipped transparent artifact and on broken copies, the preset install /
replace / cap / conflict / remove flows; the request writer and state reader). `sudo /usr/local/bin/usb16x16-apply --check` validates a pending
request without acting.

## What it deliberately cannot do

| Not implemented | Why |
| --- | --- |
| Restart a service, switch to a non-accepted profile | Owning a PCM device and interrupting audio belongs to the privileged applier, which takes exactly one request shape: an accepted profile name. This process is unprivileged and its only write outside the preset store is that request file. |
| Edit a profile's transport fields, install a preset under any other path, run an engine | User presets are the one write to `/etc/usb16x16/dsp` and to the conf, and it is the applier's, with the guards above; transport fields are always dsp-direct's. No CamillaDSP runs; the bridge's stage is the engine. |
| Live meters | The bridge has no metering tap. Opening a second ALSA stream to read levels would compete with the audio path, so `/api/health` reports `meters.available: false` and the UI's meters stay labelled as display activity. |
| Read `/api/sink/status/N` | That endpoint's arrival-lead minimum **resets when read**. The latency harness owns it; a polling dashboard would silently invalidate every lead comparison. |

`POST` to `/api/service/*`, `/api/dsp/*` or any other `/api/apply/*` route
answers `501` with that explanation rather than 404, so the boundary is
visible from the API.

## Load against the audio stack

One collector thread owns every read and publishes a cached snapshot; HTTP
handlers only copy it. Ten browsers therefore cost the Pi exactly what one
does. Three tiers:

| Tier | Period | Reads |
| --- | --- | --- |
| fast | 1 s | `/run/usb16x16/last-bridge`, `stage`, `recovers`, `web-apply/current.json` |
| slow | 5 s | `systemctl is-active` (the units and `usb16x16-apply.path`), `/etc/usb16x16/aes67.conf` (profile blocks), `/sys/class/net`, `/sys/class/udc`, `vcgencmd`, loadavg |
| daemon | 10 s | `aes67-daemon` `/api/ptp/status`, `/api/config`, `/api/sinks`, `/api/sources` |

The browser polls `/api/health` every 2 s and stops while its tab is hidden.
The unit runs at `Nice=15`, `IOSchedulingClass=idle` and `CPUWeight=20`.

## Authentication

Every route is behind HTTP Basic auth, static files included. The service
**refuses to start with no users**, so a missing or unreadable credentials file
fails closed rather than quietly serving open; `--no-auth` is the only way to
serve without it and it says so on stderr at every start.

Credentials live in `~/usb-16x16-work/web-auth`, one line per user, mode 0600:

```
name:pbkdf2_sha256$<iterations>$<salt b64>$<hash b64>
```

PBKDF2-HMAC-SHA256 at 210,000 iterations, 16-byte random salt, compared with
`hmac.compare_digest`. Add or replace a user — as `bdimaio`, not root, so the
file stays owned by the service's user:

```sh
/usr/local/bin/usb16x16-web --auth-file ~/usb-16x16-work/web-auth --add-user bryan
sudo systemctl restart usb16x16-web.service
```

It prompts twice and never takes the password on the command line, so it stays
out of argv, `/proc`, the shell history and the journal. `--remove-user NAME`
deletes one and refuses to delete the last.

### Cost and rate limiting

A KDF is the point of a password hash, but the UI polls `/api/health` every 2 s.
Paying PBKDF2 per request would put a permanent load on the machine running the
audio, so a credential that has just verified is remembered for 300 s, keyed by
the SHA-256 of its header: about 0.4 ms on the cached path against ~30 ms for a
full verify. Only a credential that already passed is ever cached.

Failed sign-ins are limited to 10 per minute per client address, after which
that address gets `429` with `Retry-After` and does not reach the KDF. Three
details matter:

- A request with **no** `Authorization` header is the Basic auth handshake, not
  a failed sign-in. Every browser makes one per session; counting it would let
  normal use throttle itself.
- The free cache is consulted **before** the limiter, so someone flooding wrong
  passwords from an address cannot lock out a user already signed in from it.
- An unknown user is hashed anyway, so a wrong name and a wrong password take
  the same time and the reply never says which was wrong.

### What Basic auth over plain HTTP does and does not give you

It stops casual access from other machines on the management LAN, and it means
preset writes have a named author. It does **not** protect the password from
anyone who can watch the traffic: Basic auth is base64, not encryption, and
there is no TLS here. Treat this as a lock on the door of a network you already
trust, not as protection against someone on the wire. Use a password you do not
use anywhere else. TLS is the next step if this ever leaves the management LAN.

## API

All routes require credentials.

```
GET    /api/health              cached snapshot; ok:false means the collector failed
GET    /api/logs?service=&lines= journalctl for a fixed unit allowlist, 1..2000 lines
GET    /api/apply/status        the applier's state (see above)
POST   /api/apply/profile       queue a switch between accepted profiles (see above)
GET    /api/presets             names and mtimes
GET    /api/presets/<name>      one preset document
PUT    /api/presets/<name>      atomic write (tmp + fsync + rename), 1 MB / 200 presets
DELETE /api/presets/<name>      remove one
GET    /<path>                  the web UI, confined to the static directory
```

A preset is UI configuration, the same document the browser exports. Saving one
processes no audio and configures no device.

## Install

Stage `usb16x16-web`, `usb16x16-web.service`, `usb16x16-apply`,
`usb16x16-apply.service`, `usb16x16-apply.path` and `install-web-control.sh`
into `~/usb-16x16-work/web-control/`, and the UI into
`~/usb-16x16-work/web-ui/`. Then, on the Pi:

```sh
sudo ~/usb-16x16-work/web-control/install-web-control.sh
/usr/local/bin/usb16x16-web --auth-file ~/usb-16x16-work/web-auth --add-user bryan
sudo systemctl enable --now usb16x16-web.service     # or restart, if already running
sudo systemctl enable --now usb16x16-apply.path      # arms Apply
```

The path unit is the switch: disabled, the UI reports Apply as not installed
and `POST /api/apply/profile` answers 503; nothing else changes.

Create the user before starting: with no users the service exits 2 rather than
serving open. The installer says so if the file is missing.

The installer verifies all five staged files against pinned SHA-256 hashes
and refuses otherwise. It reloads systemd and creates the spool
(`~/usb-16x16-work/web-apply`, owned by bdimaio, with a root-owned
`receipts/`); it does not touch `usb-16x16.service`, `usb16x16-aes67.service`
or the governor.

Pinned hashes are recorded in the installer. Recompute with `sha256sum` after
any edit and update the `expected_*_sha256` lines.

Rollback:

```sh
sudo systemctl disable --now usb16x16-apply.path usb16x16-web.service
sudo rm -f /etc/systemd/system/usb16x16-web.service /usr/local/bin/usb16x16-web \
  /etc/systemd/system/usb16x16-apply.path /etc/systemd/system/usb16x16-apply.service \
  /usr/local/bin/usb16x16-apply
sudo systemctl daemon-reload
```

Removing it leaves the audio stack untouched, and the UI keeps working as a
local prototype with presets back in browser storage.

## Running it without installing

```sh
~/usb-16x16-work/web-control/usb16x16-web \
  --static ~/usb-16x16-work/web-ui --presets ~/usb-16x16-work/web-presets \
  --auth-file ~/usb-16x16-work/web-auth --port 8088
```

No root, no unit, nothing persistent. Ctrl-C stops it.

## Binding and exposure

With no `--bind`, the service binds the address of `--management-interface`
(default `wlan0`), so it is reachable on the management LAN and **not** on the
AoIP interface. Requests are authenticated but not encrypted; see
Authentication above for what that is and is not worth. Port 8088 by default,
so it does not collide with the AES67 daemon on 8080.

## Environment overrides

`USB16X16_RUN_DIR`, `USB16X16_DAEMON_API`, `USB16X16_AOIP_IF`,
`USB16X16_MGMT_IF`, `USB16X16_CAMILLA`, `USB16X16_APPLY_DIR`,
`USB16X16_AES67_CONF` (the applier reads the last two as well, plus
`USB16X16_SUPERVISOR` and `USB16X16_BRIDGE`). Paths and auth come from flags,
not the environment. Useful for running the service on a
workstation, where every Pi-specific read simply reports unavailable rather
than failing.
