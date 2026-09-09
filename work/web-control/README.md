# `usb16x16-web` — read-only control service

The backend the web UI talks to. It serves `work/web-ui` and a small JSON API
describing the running stack: service states, bridge telemetry, PTP, AoIP
streams, network and thermal state, the journal, and durable presets.

This is step 2 of the delivery sequence in `work/web-ui/README.md`
("Read-only backend: live health and metering behind bounded collection").
It is **not** step 5. Nothing here can change device state.

## What it deliberately cannot do

| Not implemented | Why |
| --- | --- |
| Restart a service, switch a profile | Owning a PCM device and interrupting audio belongs to a narrow privileged supervisor. This process is unprivileged and has no path to one. |
| Apply DSP / compile a preset to CamillaDSP YAML | No compiler exists. The engine binary is staged on the Pi but nothing runs it. `/api/health` reports `dsp.available: false` and the UI shows DSP mode as under development. |
| Live meters | The bridge has no metering tap. Opening a second ALSA stream to read levels would compete with the audio path, so `/api/health` reports `meters.available: false` and the UI's meters stay labelled as display activity. |
| Read `/api/sink/status/N` | That endpoint's arrival-lead minimum **resets when read**. The latency harness owns it; a polling dashboard would silently invalidate every lead comparison. |

`POST` to `/api/service/*`, `/api/apply/*` or `/api/dsp/*` answers `501` with
that explanation rather than 404, so the boundary is visible from the API.

## Load against the audio stack

One collector thread owns every read and publishes a cached snapshot; HTTP
handlers only copy it. Ten browsers therefore cost the Pi exactly what one
does. Three tiers:

| Tier | Period | Reads |
| --- | --- | --- |
| fast | 1 s | `/run/usb16x16/last-bridge`, `stage`, `recovers` |
| slow | 5 s | `systemctl is-active`, `/sys/class/net`, `/sys/class/udc`, `vcgencmd`, loadavg |
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
GET    /api/presets             names and mtimes
GET    /api/presets/<name>      one preset document
PUT    /api/presets/<name>      atomic write (tmp + fsync + rename), 1 MB / 200 presets
DELETE /api/presets/<name>      remove one
GET    /<path>                  the web UI, confined to the static directory
```

A preset is UI configuration, the same document the browser exports. Saving one
processes no audio and configures no device.

## Install

Stage `usb16x16-web`, `usb16x16-web.service` and `install-web-control.sh` into
`~/usb-16x16-work/web-control/`, and the UI into `~/usb-16x16-work/web-ui/`.
Then, on the Pi:

```sh
sudo ~/usb-16x16-work/web-control/install-web-control.sh
/usr/local/bin/usb16x16-web --auth-file ~/usb-16x16-work/web-auth --add-user bryan
sudo systemctl enable --now usb16x16-web.service
```

Create the user before starting: with no users the service exits 2 rather than
serving open. The installer says so if the file is missing.

The installer verifies both staged files against pinned SHA-256 hashes and
refuses otherwise. It reloads systemd; it does not touch `usb-16x16.service`,
`usb16x16-aes67.service` or the governor.

Pinned hashes are recorded in the installer. Recompute with `sha256sum` after
any edit and update `expected_service_sha256` / `expected_unit_sha256`.

Rollback:

```sh
sudo systemctl disable --now usb16x16-web.service
sudo rm -f /etc/systemd/system/usb16x16-web.service /usr/local/bin/usb16x16-web
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
`USB16X16_MGMT_IF`, `USB16X16_CAMILLA`. Paths and auth come from flags, not the
environment. Useful for running the service on a
workstation, where every Pi-specific read simply reports unavailable rather
than failing.
