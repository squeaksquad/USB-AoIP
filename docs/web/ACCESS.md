# Access to the web page: how it is built

What stands between a browser and the audio service, and why each piece is
there. Built 2026-11-10 (packaging workstream 3) from the proposal in
`AUDIT-2026-11-10.md`. On the author's Pi since 2026-11-13 (handoff); the
from-scratch installer's form of it has not been run on a Pi
(`docs/install/TO-VERIFY.md`). "What the page can ask for" was added with the
System actions (2026-11-17, web 1.8.0 and applier 1.10.0), installed on the
author's Pi the same day. "The monitor path" was added with the monitor
block (2026-11-18, web 1.9.0 and applier 1.11.0), which is not installed
anywhere yet.

```
browser ──HTTPS, Basic auth──▶ usb16x16-web  (account usb-aoip-web, sandboxed)
                                   │ drops <id>.request (+ <id>.dsp)
                                   ▼
                    /var/spool/usb-aoip/inbox   root:usb-aoip-web 1730
                                   │ usb16x16-apply.path (PathChanged)
                                   ▼
                              usb16x16-apply  (root, oneshot)
                                   │ writes current.json, receipts/, monitor-limits
                                   ▼
                    /var/lib/usb16x16-apply     root:root 0755  ──read──▶ usb16x16-web

The monitor path (web 1.9.0): a knob does not go through the applier.

usb16x16-web ──writes──▶ /run/usb-aoip-monitor/state      usb-aoip-web 0755 / 0644
                                   │ polled every 10 ms, validated, clamped to
                                   ▼ /var/lib/usb16x16-apply/monitor-limits
                         the Dante owner  (account usb16x16-dante)
                                   │ writes monitor.status
                                   ▼
                    /run/usb16x16-dante  ──read──▶ usb16x16-web
```

## The pieces

**The page's service runs as its own account.** `WEB_USER` in
`install.conf`, `usb-aoip-web` by default, created by the installer with no
shell and no home of its own. Its unit can write three places: its preset
directory, the request inbox and, since web 1.9.0, the monitor's state
(below, "The monitor path"). It reads the audio services' journal through
the `systemd-journal` group.

**Requests go through a directory the web account can only drop files
into.** The inbox is root's, group the web account's, mode `1730`: the web
account can create a file and rename its own; it cannot list the directory,
and the sticky bit keeps it from replacing or removing anything it did not
create. For each request the service writes any uploaded DSP artifact first,
then `<id>.request`, each under a fresh random id.

**Root trusts nothing in the inbox.** The applier opens each file without
following links, accepts only a regular file with one link, reads a bounded
number of bytes, and removes it. The request's id must match its file name;
its time must be within two minutes; an id already answered is refused. Only
then does the request's kind act. A sample-rate change is never accepted
from the inbox: it comes only from the audio service's own request file.

**Root's own files are where only root writes.** The applier's status
(`current.json`), receipts, lock and rate history live in
`/var/lib/usb16x16-apply`. The web service reads `current.json` (and, since
1.9.0, `monitor-limits`) there and writes nothing. Before this, they shared the request directory, which the
web account owned, and a planted symbolic link could make root write
anywhere.

**A page on another site cannot drive the unit.** Every state-changing
request must carry the header `X-USB-AoIP: 1` and a JSON content type, and
an `Origin`, when the browser sends one, must match the address the request
came to. A browser will not let another site's page set that header without
asking the service first, and the service refuses to be asked. Basic auth
alone does not stop this: the browser attaches the login to any request to
the unit, whoever wrote the page that sent it.

**The password is encrypted on the wire by default.** `WEB_TLS=self-signed`
has the installer make a key and a certificate for the unit's hostname and
address, and the service wraps its socket with Python's standard `ssl`.
The certificate is signed by nobody, so each browser warns once per unit;
the installer prints the certificate's fingerprint so the warning can be
checked against it rather than clicked through. `WEB_TLS=provided` takes
your own certificate; `off` is plain HTTP, for a network nobody else is on.
A certificate from a public authority is not on offer for a device on a
private address unless you run DNS for it; that is what `provided` is for.
The certificate is remade when the address it must answer on changes.

**Where it listens is yours to set.** `MGMT_IF` names the interface;
`WEB_BIND` names an address outright. If the interface has no address when
the service starts, it exits and systemd starts it again a few seconds
later, rather than listening on loopback where nobody can reach it.

**Logins are made on the device.** `sudo install/install.sh set-password
NAME` asks for the password twice at the terminal; it never appears on a
command line or in a log. The file is `/etc/usb-aoip/web-auth`, root's,
readable by the web account's group: the service can check a password and
cannot change one. With no login the service does not start. `install`
offers to make the first login when it is run at a terminal.

**The clock service can run as an ordinary user, when you choose.**
`PTP_SANDBOX=1` runs Statime as the audio account with the two capabilities
it needs (binding the PTP ports, binding to the interface) and moves its
socket from `/tmp`, where any local user can reach it, to a directory in
`/run` only the audio account can enter. Both ends take the path from
configuration (`usrvclock-path` in Statime, `CLOCK_PATH` in the Inferno
ALSA config), so nothing is patched. It is off by default because it changes
three files of the accepted audio path and has not been measured:
`docs/INSTALL.md`, "The clock service as an ordinary user".

**The page can show whether the clock has a leader, when you choose.**
`PTP_STATE=1` builds Statime with a draft patch that publishes its PTP port
state to a file the page's service reads. Without it the page says the clock
state is unknown, because the pinned Statime reports nothing that shows it.
Off by default: it changes the clock service's binary and has not been run.

## What the page can ask for

Every change is a request kind the applier knows; nothing in a request is
executed. Since applier 1.11.0 the kinds are: a profile or preset switch, a
preset removal, a live update, a commit, shut down, the System tab's five
actions, and the monitor's two limits kinds. The one change that is not a
request is a monitor knob (below, "The monitor path").

**Reboot, restart audio, restart clock service.** Each is one fixed
`systemctl` sequence the applier chooses; the request says only which. The
web service asks for a body that names the action, so a stray POST does
nothing. Restarting the clock service restarts the audio service with it
(the endpoint's unit is part of the clock's), and the applier verifies the
endpoint afterwards as it does after any restart.

**The support bundle is written by root and read by the web account only.**
Root can read the journals and the audio configuration; the web account
cannot, and should not be able to. The applier writes one JSON file into
`bundles/` in its state directory, a directory only root and the web
account's group can enter, and the web service serves it by the request's
id, to a signed-in browser. The applier never reads the login file,
anything under `/etc/usb-aoip` or key material into it, whatever a path
leads to. The two newest bundles are kept.

**A password change sends root a hash, not a password.** The page sends the
new password to the web service over the same connection the login uses.
The service hashes it (the login file's own PBKDF2) and queues the hash for
the signed-in user; the plain password is never written anywhere. The
applier accepts only a hash in that exact form with a sane iteration count,
only for a user who already has a line (a request cannot add a login), and
replaces that line alone, keeping the file's owner, group and mode. The
hash is in no receipt or log. The web service notices the file change on
the next request and stops accepting the old password at once. There is no
"current password" field: the request already carries the login. With
`WEB_TLS=off` the new password crosses the network in the clear, as the
login does on every request.

**The monitor's limits are root's.** `monitor-limits` sets the knob's
maximum, the start rule and level and the reference lock;
`monitor-reference` sets one set's reference level and note. The applier
reads its own `monitor-limits` file strictly, merges the request, clamps the
start level and every reference to the maximum and writes it 0644; the
owner polls it, so nothing restarts. A reference is refused while the lock
is on, by the web service and again by the applier; unlocking is a
`monitor-limits` request like any other. The web service offers both on the
Dante stack only, the one whose engine reads the file.

## The monitor path

The monitor block (volume, dim, mute, solo, the speaker set, fold-downs)
needs a knob move to reach the audio within a few tens of milliseconds, a
dozen times a second while a knob is dragged. Through the applier each one
would be a new root Python process, a receipt and a journal entry. So the
web service writes one small file itself, `/run/usb-aoip-monitor/state`,
which the Dante owner polls every 10 ms, and a remembered copy in
`/var/lib/usb-aoip-monitor`, written 2 s after the last change so that a drag
is one write to the SD card. systemd makes both directories for the web
unit (`RuntimeDirectory=`, `StateDirectory=`, 0755); under
`ProtectSystem=strict` they are writable by it alone, and the files are
0644 so the owner's account can read them. `MONITOR-FILES.md` has the three
files' formats.

This is a third place the web account can write, and it does not weaken the
design:

- **The reader is not root.** The owner runs as the audio account, with no
  more rights than it needs to play audio. Nothing privileged reads the
  file; the applier never does.
- **The reader trusts nothing in it.** The owner reads it without following
  links, to a size cap, by a strict line format; anything that does not
  parse is refused whole and the previous state stays in force. Every
  number is range-checked and every level clamped to the limits before it
  reaches the audio.
- **The limits stay root's.** The knob's maximum, the start rule and the
  reference levels are in `monitor-limits` in root's state directory,
  written only by the applier on a request (above). The web account cannot
  raise the maximum except by asking, as a signed-in user would.
- **The worst case is what a signed-in user can do.** A compromised web
  service can write any valid state: turn the monitors up to the maximum,
  mute them, solo an output. A signed-in user can do all of that from the
  page. It cannot exceed the limits, write anywhere else or reach root
  through the file.

The owner reports what is in force, and the running preset's sets and
outputs, in `/run/usb16x16-dante/monitor.status`, which the web service
reads. A knob works while an Apply is running: the route has the same sign-in
and cross-site checks as every change, but not the applier's
one-operation-at-a-time gate.

## What it does not do

- It does not make the page safe to expose to the internet. It is a control
  surface for a device on a local network.
- It has no accounts with different rights: anyone with a login can do
  everything the page can, including shutting the unit down, rebooting it
  and changing their own password. Anyone who can sign in as a user can
  change that user's password.
- A self-signed certificate does not prove the unit is yours the first time;
  the fingerprint does, if you compare it.
- The applier is still root, because restarting the audio service and
  rewriting its configuration need it. It is a oneshot with a small
  sandbox, not a daemon.
- Statime with `PTP_SANDBOX=0` is root, as measured.

## Why not

- **A unix socket instead of the inbox.** It would remove the file handling
  but needs a root listener that is always running, or socket activation
  with a protocol of its own, and a request would no longer outlive a
  restart of either side.
- **Sessions and a login form instead of Basic auth.** More code in a
  service that is standard library only, to end at the same place: a secret
  sent with every request over TLS. The header check does what a session
  token's cross-site protection would.
- **A first-run setup page in the browser.** It needs a route that works
  before any login exists and a one-time token to guard it. A command at
  the terminal the installer is already running in is smaller.
- **A dependency** (a web framework, an ACME client, a TLS proxy). Nothing
  here needed one; `openssl` for the certificate is already on the system.
