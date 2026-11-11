# Access to the web page: how it is built

What stands between a browser and the audio service, and why each piece is
there. Built 2026-11-10 (packaging workstream 3) from the proposal in
`AUDIT-2026-11-10.md`; nothing here has been run on a Pi yet
(`docs/install/TO-VERIFY.md`).

```
browser ──HTTPS, Basic auth──▶ usb16x16-web  (account usb-aoip-web, sandboxed)
                                   │ drops <id>.request (+ <id>.dsp)
                                   ▼
                    /var/spool/usb-aoip/inbox   root:usb-aoip-web 1730
                                   │ usb16x16-apply.path (PathChanged)
                                   ▼
                              usb16x16-apply  (root, oneshot)
                                   │ writes current.json, receipts/
                                   ▼
                    /var/lib/usb16x16-apply     root:root 0755  ──read──▶ usb16x16-web
```

## The pieces

**The page's service runs as its own account.** `WEB_USER` in
`install.conf`, `usb-aoip-web` by default, created by the installer with no
shell and no home of its own. Its unit can write two places: its preset
directory and the request inbox. It reads the audio services' journal
through the `systemd-journal` group.

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
`/var/lib/usb16x16-apply`. The web service reads `current.json` there and
writes nothing. Before this, they shared the request directory, which the
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

## What it does not do

- It does not make the page safe to expose to the internet. It is a control
  surface for a device on a local network.
- It has no accounts with different rights: anyone with a login can do
  everything the page can, including shutting the unit down.
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
