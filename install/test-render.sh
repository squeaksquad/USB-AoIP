#!/bin/bash
# What can be checked of the installer without a Pi and without root:
#   1. the pins hold: every patch and source file is the pinned one, and the
#      upstream revisions are the ones dante/SOURCES.lock records;
#   2. with the development unit's values, every rendered file is byte for
#      byte the repository file that unit runs, so the installer installs the
#      point of record and not something like it;
#   3. with another unit's values, nothing rendered carries the development
#      unit's names, addresses or identities, and its own values are there;
#   4. bad config values are refused.
# Run: bash install/test-render.sh
set -uo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/usb-aoip-render.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

# --- 1. pins
while read -r want path; do
  [ -n "$want" ] || continue
  [ "$(sha "$repo/$path")" = "$want" ] || bad "pin: $path is not ${want:0:8}"
done < "$repo/install/pins.sha256"
while read -r name value; do
  case "$name" in ''|'#'*|*_url|rust_toolchain) continue ;; esac
  grep -q "$value" "$repo/dante/SOURCES.lock" || bad "sources.pins: $name $value is not in dante/SOURCES.lock"
done < "$repo/install/sources.pins"
grep -q "rustc *$(sed -n 's/^rust_toolchain *//p' "$repo/install/sources.pins") " "$repo/dante/SOURCES.lock" || bad "sources.pins: the Rust toolchain is not SOURCES.lock's"
[ $fail = 0 ] && ok "pins: patches, sources and upstream revisions"

# --- 2. the development unit renders to the repository's own files
dev=$tmp/dev
"$repo/install/install.sh" render --root "$dev" --config "$repo/install/test/development-unit.conf" >/dev/null || bad "render (development unit) failed"
u=/etc/systemd/system; w=/home/bdimaio/usb-16x16-work
same() {   # same RENDERED-PATH REPO-FILE
  if [ ! -f "$dev$1" ]; then bad "development unit: $1 was not rendered"
  elif ! cmp -s "$dev$1" "$repo/$2"; then bad "development unit: $1 differs from $2"; fi
}
before=$fail; [ -f "$dev/manifest.rendered" ] || touch "$dev/manifest.rendered" 2>/dev/null
same $u/usb16x16-statime.service                        dante/service/usb16x16-statime.service
same $u/usb16x16-dante.service                          dante/service/usb16x16-dante-dsp-linkwait.service
same $u/usb16x16-dante-startcheck.service               dante/service/usb16x16-dante-startcheck.service
same $u/usb16x16-dante-rate.path                        dante/service/usb16x16-dante-rate.path
same $u/usb16x16-dante-rate.service                     dante/service/usb16x16-dante-rate.service
for f in dante statime dante-startcheck dante-rate; do
  same $u/usb16x16-$f.service.d/10-usb-aoip.conf        dante/service/10-usb-aoip-$f.conf
done
same /usr/local/libexec/usb16x16-dante/usb16x16-dante-start      dante/service/usb16x16-dante-start-transport
same /usr/local/libexec/usb16x16-dante/usb16x16-dante-startcheck dante/service/usb16x16-dante-startcheck
same /etc/usb16x16/dante/transport.conf                 dante/service/transport-rate882.conf
same /etc/usb16x16/dante/startcheck.conf                dante/service/startcheck.conf
same /etc/usb16x16/dante/owner.conf                     dante/service/owner.conf.default
same /etc/usb16x16/dante/asound-inferno-owner.conf      dante/config/asound-inferno-owner-usb-aoip-rate882.conf
same /etc/usb16x16/dante/statime.toml                   dante/config/statime-first-run.toml
same /etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf dante/service/90-usb16x16-eth0-carrier.conf
same /etc/sysctl.d/90-usb16x16-compaction.conf          dante/service/90-usb16x16-compaction.conf
same /usr/local/sbin/setup-usb-aoip                     gadget/setup-usb-aoip
same /usr/local/sbin/usb16x16-stall-tuning              gadget/stall-tuning.sh
same $u/usb16x16-governor.service                       gadget/usb16x16-governor.service
same $u/usb16x16-wlan-keepalive.service                 gadget/usb16x16-wlan-keepalive.service
same /usr/local/bin/usb16x16-web                        web-control/usb16x16-web
same /usr/local/bin/usb16x16-apply                      web-control/usb16x16-apply
same $u/usb16x16-web.service                            web-control/usb16x16-web.service
same $u/usb16x16-apply.path                             web-control/usb16x16-apply.path
same $u/usb16x16-apply.service                          web-control/usb16x16-apply.service
same $w/web-ui/app.mjs                                  web-ui/app.mjs
same $w/web-ui/compiler/compile.mjs                     dsp-compiler/compile.mjs
# The sudoers rule is the one the old chain's installer wrote.
sed -n "/^cat > \"\$sudoers_temporary\" <<'EOF'/,/^EOF/p" "$repo/history/installers/dante/service/install-dante-service.sh" | sed '1d;$d' > "$tmp/sudoers.chain"
cmp -s "$dev/etc/sudoers.d/usb16x16-dante" "$tmp/sudoers.chain" || bad "development unit: the sudoers rule differs from the chain's"
# The pinned hashes of the audio-path files, as the handoff records them.
pinned() { [ "$(sha "$dev$1" | cut -c1-8)" = "$2" ] || bad "development unit: $1 is $(sha "$dev$1" | cut -c1-8), the point of record has $2"; }
pinned /usr/local/libexec/usb16x16-dante/usb16x16-dante-start df6a1b0b
pinned /etc/usb16x16/dante/transport.conf                     add1bc21
pinned /etc/usb16x16/dante/asound-inferno-owner.conf          85a5256f
pinned /etc/usb16x16/dante/statime.toml                       11b055df
pinned $u/usb16x16-dante.service                              27b68877
pinned /usr/local/sbin/setup-usb-aoip                         65d26567
# (The page's service and the applier changed with the access work of
# 2026-11-10 and are no longer the development unit's 6b98e7cf / 347a7062.)
[ $fail = $before ] && ok "development unit: $(wc -l < "$dev/manifest.rendered" | tr -d ' ') files rendered, each identical to the repository's; audio-path hashes are the point of record's"

# --- 3. another unit carries its own values and nothing of the development unit
new=$tmp/new
before=$fail
"$repo/install/install.sh" render --root "$new" --config "$repo/install/test/fresh-unit.conf" --with-dev-tools >/dev/null || bad "render (fresh unit) failed"
leak=$(grep -rIlE 'bdimaio|Bryan|DiMaio|192\.168\.|169\.254\.[1-9]|AUDDEV001|88a29e8b|audio-dev|/home/' "$new" 2>/dev/null | grep -v manifest.rendered)
[ -z "$leak" ] || bad "fresh unit: development-unit identifiers in: $(echo $leak | sed "s|$new||g")"
has() { grep -qF -- "$2" "$new$1" 2>/dev/null || bad "fresh unit: $1 lacks '$2'"; }
has /etc/usb16x16/dante/asound-inferno-owner.conf 'NAME "Studio-B"'
has /etc/usb16x16/dante/asound-inferno-owner.conf 'DEVICE_ID "2ccf67aabbcc0000"'
has /etc/usb16x16/dante/asound-inferno-owner.conf 'BIND_IP "end0"'
has /etc/usb16x16/dante/statime.toml              'interface = "end0"'
has $u/usb16x16-dante.service                     '/sys/class/net/end0/carrier'
has /etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf 'match-device=interface-name:end0'
has /usr/local/libexec/usb16x16-dante/usb16x16-dante-startcheck 'USB16X16_STARTCHECK_IFACE:-end0'
has /usr/local/sbin/setup-usb-aoip                "UA1A2B3C4D > "
has /usr/local/sbin/setup-usb-aoip                "'USB-AoIP project' > "
has /usr/local/sbin/setup-usb-aoip                "'Studio-B' > \"\$G/strings/0x409/product\""
has $u/usb16x16-web.service                       'User=usb-aoip-web'
has $u/usb16x16-web.service                       '--static /var/lib/usb-aoip/web-ui'
has $u/usb16x16-web.service                       '--management-interface wlan1'
has $u/usb16x16-web.service                       '--port 9090'
has $u/usb16x16-apply.path                        'PathChanged=/var/spool/usb-aoip/inbox'
has $u/usb16x16-web.service                       '--auth-file /etc/usb-aoip/web-auth'
has $u/usb16x16-web.service                       'ReadWritePaths=/var/lib/usb-aoip/web-presets /var/spool/usb-aoip/inbox'
has /etc/sudoers.d/usb16x16-dante                 'pi ALL=(root) NOPASSWD:'
[ ! -e "$new$u/usb16x16-wlan-keepalive.service" ] || bad "fresh unit: a keepalive unit was rendered with no targets"
# The audio path is the same on every unit: only names and addresses differ.
for f in /usr/local/libexec/usb16x16-dante/usb16x16-dante-start /etc/usb16x16/dante/transport.conf /etc/usb16x16/dante/startcheck.conf /etc/sysctl.d/90-usb16x16-compaction.conf; do
  cmp -s "$new$f" "$dev$f" || bad "fresh unit: $f differs from the development unit's"
done
diff <(grep -vE '^[[:space:]]*(NAME|DEVICE_ID|BIND_IP) |eth0|end0' "$dev/etc/usb16x16/dante/asound-inferno-owner.conf") \
     <(grep -vE '^[[:space:]]*(NAME|DEVICE_ID|BIND_IP) |eth0|end0' "$new/etc/usb16x16/dante/asound-inferno-owner.conf") >/dev/null ||
  bad "fresh unit: the Inferno config differs in more than its name, device ID and interface"
diff <(grep -vE 'serialnumber|manufacturer|Studio-B|USB-AoIP' "$dev/usr/local/sbin/setup-usb-aoip") \
     <(grep -vE 'serialnumber|manufacturer|Studio-B|USB-AoIP' "$new/usr/local/sbin/setup-usb-aoip") >/dev/null ||
  bad "fresh unit: the gadget script differs in more than its identity strings"
[ $fail = $before ] && ok "fresh unit: its own values throughout, no development-unit identifiers, the audio-path files unchanged"

# --- 3b. the clock sandbox is opt-in and changes only what it says
before=$fail
{ grep -v '^PTP_SANDBOX=' "$repo/install/test/fresh-unit.conf"; echo PTP_SANDBOX=1; } > "$tmp/ptp.conf"
ptp=$tmp/ptp
"$repo/install/install.sh" render --root "$ptp" --config "$tmp/ptp.conf" --with-dev-tools >/dev/null || bad "render (clock sandbox) failed"
sock=/run/usb16x16-statime/ptp-usrvclock
for f in $u/usb16x16-statime.service $u/usb16x16-dante.service /etc/usb16x16/dante/statime.toml /etc/usb16x16/dante/asound-inferno-owner.conf; do
  grep -q "$sock" "$ptp$f" || bad "clock sandbox: $f does not name $sock"
  grep -q '/tmp/ptp-usrvclock' "$ptp$f" && bad "clock sandbox: $f still names the /tmp socket"
  grep -q "$sock" "$new$f" && bad "clock sandbox off: $f names $sock"
done
grep -q '^User=usb16x16-dante$' "$ptp$u/usb16x16-statime.service" || bad "clock sandbox: Statime has no User="
grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW$' "$ptp$u/usb16x16-statime.service" || bad "clock sandbox: capabilities missing"
grep -q '^User=' "$new$u/usb16x16-statime.service" && bad "clock sandbox off: Statime has a User="
# Everything else is the same file by file.
( cd "$new" && find . -type f ! -name manifest.rendered | sort ) | while read -r f; do
  case "$f" in ./etc/systemd/system/usb16x16-statime.service|./etc/systemd/system/usb16x16-dante.service|./etc/usb16x16/dante/statime.toml|./etc/usb16x16/dante/asound-inferno-owner.conf|./usr/local/sbin/usb16x16-dante-candidate) continue ;; esac
  cmp -s "$new/$f" "$ptp/$f" || echo "$f"
done > "$tmp/ptp.diff"
[ -s "$tmp/ptp.diff" ] && bad "clock sandbox: other files changed: $(tr '\n' ' ' < "$tmp/ptp.diff")"
[ "$(diff "$new/etc/usb16x16/dante/asound-inferno-owner.conf" "$ptp/etc/usb16x16/dante/asound-inferno-owner.conf" | grep -c '^[<>]')" = 1 ] || bad "clock sandbox: the Inferno config differs by more than the one CLOCK_PATH line"
[ $fail = $before ] && ok "clock sandbox: off renders the accepted files; on changes four files (and the candidate launcher) and only by the socket path, the user and the sandbox lines"

# --- 3c. the clock's port state is opt-in and touches only the Statime unit
before=$fail
{ grep -v '^PTP_STATE=' "$repo/install/test/fresh-unit.conf"; echo PTP_STATE=1; } > "$tmp/state.conf"
st=$tmp/state
"$repo/install/install.sh" render --root "$st" --config "$tmp/state.conf" --with-dev-tools >/dev/null || bad "render (port state) failed"
grep -q '^Environment=STATIME_PORT_STATE_FILE=/run/usb16x16-clock/port-state$' "$st$u/usb16x16-statime.service" || bad "port state: the Statime unit does not set the file"
grep -q '^d /run/usb16x16-clock 0755 root root -$' "$st/etc/tmpfiles.d/usb-aoip-clock.conf" || bad "port state: no tmpfiles entry for the directory"
grep -q 'STATIME_PORT_STATE_FILE' "$new$u/usb16x16-statime.service" && bad "port state off: the Statime unit sets the file"
[ ! -e "$new/etc/tmpfiles.d/usb-aoip-clock.conf" ] || bad "port state off: a tmpfiles entry was rendered"
( cd "$st" && find . -type f ! -name manifest.rendered | sort ) | while read -r f; do
  case "$f" in ./etc/systemd/system/usb16x16-statime.service|./etc/tmpfiles.d/usb-aoip-clock.conf) continue ;; esac
  cmp -s "$new/$f" "$st/$f" || echo "$f"
done > "$tmp/state.diff"
[ -s "$tmp/state.diff" ] && bad "port state: other files changed: $(tr '\n' ' ' < "$tmp/state.diff")"
[ "$(diff "$new$u/usb16x16-statime.service" "$st$u/usb16x16-statime.service" | grep -c '^>')" = 3 ] || bad "port state: the Statime unit differs by more than its three added lines"
[ $fail = $before ] && ok "clock port state: off renders the accepted Statime unit; on adds three lines to it and one tmpfiles entry, nothing else"

# --- 4. bad values are refused
before=$fail
refused() {   # refused KEY VALUE
  sed "s|^$1=.*|$1=$2|" "$repo/install/test/fresh-unit.conf" > "$tmp/bad.conf"
  if "$repo/install/install.sh" render --root "$tmp/bad" --config "$tmp/bad.conf" >/dev/null 2>&1; then bad "config: $1='$2' was accepted"; fi
}
refused AUDIO_IF 'eth0; reboot'
refused WORK_DIR '/var/lib/../etc'
refused WORK_DIR 'relative/path'
refused OPERATOR_USER 'root ALL=(ALL) NOPASSWD: ALL'
refused DEVICE_NAME 'a"b'
refused USB_MANUFACTURER "it's"
refused USB_SERIAL ''
refused DANTE_DEVICE_ID 'XYZ'
refused DANTE_RATES '48000'
refused WEB_PORT '80'
refused KERNEL_PIN '$(id)'
refused WEB_TLS 'yes'
refused WEB_BIND 'localhost; id'
refused PTP_SANDBOX '2'
refused PTP_STATE 'yes'
{ cat "$repo/install/test/fresh-unit.conf"; echo "NOT_A_KEY=1"; } > "$tmp/bad.conf"
"$repo/install/install.sh" render --root "$tmp/bad" --config "$tmp/bad.conf" >/dev/null 2>&1 && bad "config: an unknown key was accepted"
[ $fail = $before ] && ok "config: bad values and unknown keys are refused"

[ $fail = 0 ] && echo "test-render: all passed" || echo "test-render: FAILED"
exit $fail
