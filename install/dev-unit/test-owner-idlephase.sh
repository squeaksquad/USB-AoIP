#!/bin/bash
# What can be checked of the owner-idlephase tooling without a Pi: against a
# directory standing in for /, holding a stand-in for the owner the development
# unit runs (a test cannot make a file that hashes to bc486911, so the owner's
# old and new hashes are injected, which the installer takes only with a
# stand-in root), the real start wrapper df6a1b0b (from the tag layout-2026-11-01)
# and the real transport.conf add1bc21 (dante/service/transport-rate882.conf),
# and systemctl and journalctl replaced by recorders.
#   - the bundle stages, is the one owner-idlephase.sha256 pins, and a changed
#     source, patch or service file fails staging; the installer's wrapper and
#     transport pins are the repository's files, its owner pins the monitor set's;
#   - install refuses while OWNER_NEW is empty (EMPTY), and the test overrides
#     are refused without a stand-in root;
#   - install replaces all three, keeps the old ones, stops and starts the unit
#     and prints the START line's idle phase; a second install does nothing;
#   - rollback restores every byte; a second one is refused; install works again;
#   - refused: a wrong owner, wrong wrapper or wrong transport.conf, a half-installed
#     set, the candidate launcher running, a rate change, an apply, a binary that is
#     not the pinned build, a tampered bundle, nothing built, a rollback with nothing
#     kept or a kept copy changed;
#   - status changes nothing.
# Run: bash install/dev-unit/test-owner-idlephase.sh   (needs the tag: a full clone)
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/usb-aoip-owner-idlephase.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
tag=layout-2026-11-01
git -C "$repo" rev-parse -q --verify "$tag^{commit}" >/dev/null || { echo "SKIP: the tag $tag is not in this clone (fetch tags)"; exit 0; }
git -C "$repo" show "$tag:work/dante-mode/service/usb16x16-dante-start-transport" > "$tmp/old-wrapper"
installer=$repo/install/dev-unit/install-owner-idlephase.sh
pin() { sed -n "s/^$1=\([0-9a-f]*\)\$/\1/p" "$2"; }

# --- staging, and the pins against the files they name
before=$fail
bash "$repo/install/dev-unit/stage-owner-idlephase.sh" "$tmp/bundle" > "$tmp/stage.out" 2>&1 || bad "staging failed (is owner-idlephase.sha256 current?): $(head -3 "$tmp/stage.out")"
[ -x "$tmp/bundle/install-owner-idlephase.sh" ] || { echo "test-owner-idlephase: FAILED"; exit 1; }
cmp -s "$tmp/bundle/owner-idlephase.sha256" "$repo/install/dev-unit/owner-idlephase.sha256" || bad "the staged list is not the repository's"
grep -q "^manifest_sha256=$(sha "$tmp/bundle/owner-idlephase.sha256")\$" "$tmp/bundle/install-owner-idlephase.sh" || bad "the installer does not carry the list's hash"
for f in src/dante/owner/main.cpp src/dante/owner/idle-phase.patch src/dante/owner/monitor_ctl.hpp src/dsp-core/src/bridge_core.cpp \
         src/dsp-core/include/usb16x16/bridge_core.hpp service/usb16x16-dante-start-transport service/transport-idlephase.conf build-owner-idlephase.sh; do
  grep -q "  $f\$" "$tmp/bundle/owner-idlephase.sha256" || bad "$f is not pinned in the list"
done
grep -Eq 'dsp_offline|CMakeLists' "$tmp/bundle/owner-idlephase.sha256" && bad "the bundle carries the DSP runner's sources"
listed=$(wc -l < "$tmp/bundle/owner-idlephase.sha256" | tr -d ' ')
present=$(cd "$tmp/bundle" && find build-owner-idlephase.sh service src -type f | wc -l | tr -d ' ')
[ "$listed" = "$present" ] || bad "the list has $listed entries for $present files"
[ "$(pin WRAPPER_NEW "$installer")" = "$(sha "$repo/dante/service/usb16x16-dante-start-transport")" ] || bad "WRAPPER_NEW is not dante/service/usb16x16-dante-start-transport"
[ "$(pin TRANSPORT_NEW "$installer")" = "$(sha "$repo/dante/service/transport-idlephase.conf")" ] || bad "TRANSPORT_NEW is not dante/service/transport-idlephase.conf"
[ "$(pin WRAPPER_OLD "$installer")" = "$(sha "$tmp/old-wrapper")" ] || bad "WRAPPER_OLD is not the wrapper of $tag"
[ "$(pin TRANSPORT_OLD "$installer")" = "$(sha "$repo/dante/service/transport-rate882.conf")" ] || bad "TRANSPORT_OLD is not dante/service/transport-rate882.conf"
[ "$(pin OWNER_OLD "$installer")" = "$(pin OWNER_NEW "$repo/install/dev-unit/install-owner-monitor.sh")" ] || bad "OWNER_OLD is not install-owner-monitor.sh's OWNER_NEW"
[ "$(pin WRAPPER_OLD "$installer")" = "$(pin START_WRAPPER "$repo/install/dev-unit/install-owner-monitor.sh")" ] || bad "WRAPPER_OLD is not the wrapper install-owner-monitor.sh requires"
# a changed source, patch or service file fails staging: a copy of the parts of the repository it reads
mkdir -p "$tmp/repo/install" "$tmp/repo/dante" "$tmp/repo/dsp-core/src"
cp -R "$repo/install/dev-unit" "$tmp/repo/install/"; cp -R "$repo/dante/owner" "$repo/dante/service" "$tmp/repo/dante/"
cp -R "$repo/dsp-core/include" "$tmp/repo/dsp-core/"; cp "$repo/dsp-core/src/bridge_core.cpp" "$tmp/repo/dsp-core/src/"
bash "$tmp/repo/install/dev-unit/stage-owner-idlephase.sh" "$tmp/copy-bundle" >/dev/null 2>&1 || bad "the copy of the repository does not stage as is"
for f in dante/owner/servo.hpp dante/owner/idle-phase.patch dante/service/usb16x16-dante-start-transport dante/service/transport-idlephase.conf; do
  cp "$tmp/repo/$f" "$tmp/saved"; echo "# changed" >> "$tmp/repo/$f"
  bash "$tmp/repo/install/dev-unit/stage-owner-idlephase.sh" "$tmp/copy-bundle" > "$tmp/changed.out" 2>&1 && bad "a changed $f staged"
  grep -q "$(basename "$f")" "$tmp/changed.out" || bad "the refusal does not name the changed $f"
  cp "$tmp/saved" "$tmp/repo/$f"
done
[ $fail = $before ] && ok "the bundle stages ($listed files, list $(sha "$tmp/bundle/owner-idlephase.sha256" | cut -c1-8)), is the pinned one, a changed file fails staging; the pins are the files they name"

# --- the stand-in unit
cat > "$tmp/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
if [ "$1" = is-active ]; then
  case " ${SYSTEMCTL_ACTIVE-usb16x16-dante.service} " in *" $2 "*) echo active ;; *) echo inactive ;; esac
fi
exit 0
STUB
cat > "$tmp/journalctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
echo "START usb16x16-dante-owner mode=usb pcm=inferno rate=48000 prime_drop=28 capture_drain=1 idle_phase_us=60"
STUB
chmod 755 "$tmp/systemctl" "$tmp/journalctl"
printf 'old owner stand-in\n' > "$tmp/old-owner"
mkdir -p "$tmp/bundle/out"
printf 'new owner stand-in\n' > "$tmp/bundle/out/usb16x16-dante-owner"
OWNER_OLD=$(sha "$tmp/old-owner") OWNER_NEW=$(sha "$tmp/bundle/out/usb16x16-dante-owner")
owner=/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner start=/usr/local/libexec/usb16x16-dante/usb16x16-dante-start
transport=/etc/usb16x16/dante/transport.conf runner=/usr/local/libexec/usb16x16-dsp-offline
fresh_root() {   # the development unit as it is: owner bc486911 (stand-in), start wrapper df6a1b0b, transport add1bc21
  root=$tmp/root.$1; rm -rf "$root"
  mkdir -p "$root/usr/local/libexec/usb16x16-dante" "$root/etc/usb16x16/dante"
  cp "$tmp/old-owner" "$root$owner"; chmod 755 "$root$owner"
  cp "$tmp/old-wrapper" "$root$start"; chmod 755 "$root$start"
  cp "$repo/dante/service/transport-rate882.conf" "$root$transport"; chmod 644 "$root$transport"
  printf 'runner stand-in\n' > "$root$runner"
  printf 'METERS=1\n' > "$root/etc/usb16x16/dante/owner.conf"
  ( cd "$root" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/before.$1"
  : > "$tmp/systemctl.log"
}
snapshot() { ( cd "$root" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ); }
env_test() { env USB_AOIP_TEST_ROOT="$root" USB_AOIP_TEST_SYSTEMCTL="$tmp/systemctl" USB_AOIP_TEST_JOURNALCTL="$tmp/journalctl" \
  USB_AOIP_TEST_SETTLE=0 SYSTEMCTL_LOG="$tmp/systemctl.log" "$@"; }
run_nopins() { env_test USB_AOIP_TEST_OWNER_OLD="$OWNER_OLD" USB_AOIP_TEST_OWNER_NEW=EMPTY "${bundle:-$tmp/bundle}/install-owner-idlephase.sh" "$@"; }
run() { env_test USB_AOIP_TEST_OWNER_OLD="$OWNER_OLD" USB_AOIP_TEST_OWNER_NEW="$OWNER_NEW" "${bundle:-$tmp/bundle}/install-owner-idlephase.sh" "$@"; }
mode_of() { ls -l "$1" | cut -c1-10; }

# --- an empty pin, and the test overrides outside a test
before=$fail
fresh_root p
run_nopins install > "$tmp/nopins.out" 2>&1 && bad "installed with OWNER_NEW empty"
grep -q 'build-owner-idlephase.sh' "$tmp/nopins.out" && grep -q 'report the hash' "$tmp/nopins.out" || bad "the empty-pin refusal does not say to build and report: $(cat "$tmp/nopins.out")"
snapshot | diff "$tmp/before.p" - >/dev/null || bad "a refused install changed files"
grep -q '^stop' "$tmp/systemctl.log" && bad "a refused install stopped a unit"
USB_AOIP_TEST_OWNER_NEW=$OWNER_NEW "$tmp/bundle/install-owner-idlephase.sh" install > "$tmp/override.out" 2>&1 && bad "a test override was taken without a stand-in root"
grep -q 'taken only with USB_AOIP_TEST_ROOT' "$tmp/override.out" || bad "the override refusal does not say why: $(cat "$tmp/override.out")"
USB_AOIP_TEST_OWNER_OLD=$OWNER_OLD "$tmp/bundle/install-owner-idlephase.sh" status > "$tmp/override2.out" 2>&1 && bad "status took a test override without a stand-in root"
[ $fail = $before ] && ok "install refuses with the owner pin empty (and says to build and report); the test overrides are refused without a stand-in root"

# --- install
before=$fail
fresh_root a
run install > "$tmp/install.out" 2>&1 || bad "install failed: $(tail -3 "$tmp/install.out")"
[ "$(sha "$root$owner")" = "$OWNER_NEW" ] || bad "install: the owner is not the new one"
cmp -s "$root$start" "$repo/dante/service/usb16x16-dante-start-transport" || bad "install: the start wrapper is not the new one"
cmp -s "$root$transport" "$repo/dante/service/transport-idlephase.conf" || bad "install: transport.conf is not the new one"
[ "$(sha "$root$owner.idlephase-previous")" = "$OWNER_OLD" ] || bad "install: the old owner was not kept"
cmp -s "$root$start.idlephase-previous" "$tmp/old-wrapper" || bad "install: the old start wrapper was not kept"
cmp -s "$root$transport.idlephase-previous" "$repo/dante/service/transport-rate882.conf" || bad "install: the old transport.conf was not kept"
[ "$(mode_of "$root$owner")" = -rwxr-xr-x ] && [ "$(mode_of "$root$start")" = -rwxr-xr-x ] || bad "install: owner $(mode_of "$root$owner"), wrapper $(mode_of "$root$start")"
[ "$(mode_of "$root$transport")" = -rw-r--r-- ] && [ "$(mode_of "$root$transport.idlephase-previous")" = -rw-r--r-- ] || bad "install: transport.conf is $(mode_of "$root$transport")"
find "$root" -name '*.idlephase-undo' -o -name '*.new' | grep -q . && bad "install: temporary copies were left behind"
grep -q "^stop usb16x16-dante.service" "$tmp/systemctl.log" || bad "install: the unit was not stopped"
grep -q "^start usb16x16-dante.service" "$tmp/systemctl.log" || bad "install: the unit was not started"
[ "$(grep -n '^stop usb16x16-dante' "$tmp/systemctl.log" | cut -d: -f1)" -lt "$(grep -n '^start usb16x16-dante' "$tmp/systemctl.log" | cut -d: -f1)" ] || bad "install: started before it stopped"
grep -Eq '^(stop|start|restart) (usb16x16-web|usb16x16-apply|usb16x16-statime|usb-16x16)' "$tmp/systemctl.log" && bad "install: it acted on another unit"
grep -q 'START line: idle_phase_us=60' "$tmp/install.out" || bad "install: the START line's idle phase was not printed"
grep -q 'usb16x16-dante.service is active' "$tmp/install.out" || bad "install: the unit's state was not printed"
[ "$(sha "$root$runner")" = "$(grep "  \./usr/local/libexec/usb16x16-dsp-offline\$" "$tmp/before.a" | cut -c1-64)" ] || bad "install: the runner changed"
grep -q '48 and at 96' "$tmp/install.out" || bad "install: the battery owed at 48 and 96 is not said"
run install > "$tmp/again.out" 2>&1; grep -q 'already installed' "$tmp/again.out" || bad "a second install did not say it was already installed"
[ $fail = $before ] && ok "install: owner, start wrapper and transport.conf replaced and kept as *.idlephase-previous, the unit stopped and started, the idle phase shown; a second install does nothing"

# --- status changes nothing
before=$fail
snapshot > "$tmp/pre-status"; : > "$tmp/systemctl.log"
run status > "$tmp/status.out" 2>&1 || bad "status failed"
snapshot | diff "$tmp/pre-status" - >/dev/null || bad "status changed files"
grep -Ev '^is-active' "$tmp/systemctl.log" | grep -q . && bad "status did more than ask is-active: $(grep -Ev '^is-active' "$tmp/systemctl.log" | head -2)"
for f in usb16x16-dante-owner usb16x16-dante-start transport.conf; do grep -q "$f  *new" "$tmp/status.out" || bad "status does not call $f new: $(cat "$tmp/status.out")"; done
fresh_root s; run_nopins status > "$tmp/status0.out" 2>&1 || bad "status with an empty pin failed"
grep -q 'pins: owner EMPTY' "$tmp/status0.out" && grep -q 'usb16x16-dante-owner  *old' "$tmp/status0.out" && grep -q 'transport.conf  *old' "$tmp/status0.out" || bad "status with an empty pin: $(head -3 "$tmp/status0.out")"
snapshot | diff "$tmp/before.s" - >/dev/null || bad "status (empty pin) changed files"
[ $fail = $before ] && ok "status changes nothing and reports new, old, kept and the pins"

# --- rollback restores every byte
before=$fail
root=$tmp/root.a; : > "$tmp/systemctl.log"
run rollback > "$tmp/rollback.out" 2>&1 || bad "rollback failed: $(tail -3 "$tmp/rollback.out")"
snapshot | diff "$tmp/before.a" - >/dev/null || bad "rollback: not every file is back as it was: $(snapshot | diff "$tmp/before.a" - | head -4 | tr '\n' ' ')"
[ "$(mode_of "$root$transport")" = -rw-r--r-- ] && [ "$(mode_of "$root$start")" = -rwxr-xr-x ] || bad "rollback: modes not restored"
grep -q "^stop usb16x16-dante.service" "$tmp/systemctl.log" && grep -q "^start usb16x16-dante.service" "$tmp/systemctl.log" || bad "rollback: the unit was not stopped and started"
run rollback > "$tmp/rb2.out" 2>&1 && bad "a second rollback went ahead"
snapshot | diff "$tmp/before.a" - >/dev/null || bad "a refused second rollback changed files"
run install >/dev/null 2>&1 || bad "install after a rollback failed"
[ "$(sha "$root$owner")" = "$OWNER_NEW" ] || bad "install after a rollback: the owner is not the new one"
[ $fail = $before ] && ok "rollback restores every byte; a second one is refused; install works again after it"

# --- refusals
before=$fail
fresh_root w; printf 'some other owner\n' > "$root$owner"; snapshot > "$tmp/pre-w"
run install > "$tmp/wrong.out" 2>&1 && bad "installed over an owner that is not bc486911"
grep -q 'not the .* this replaces' "$tmp/wrong.out" || bad "the wrong-owner refusal does not say why: $(cat "$tmp/wrong.out")"
snapshot | diff "$tmp/pre-w" - >/dev/null || bad "a refused install (wrong owner) changed files"
fresh_root x; echo "# edited" >> "$root$start"; snapshot > "$tmp/pre-x"
run install >/dev/null 2>&1 && bad "installed over a start wrapper that is not df6a1b0b"
snapshot | diff "$tmp/pre-x" - >/dev/null || bad "a refused install (wrong wrapper) changed files"
fresh_root t; echo "RX_QUEUE=112" >> "$root$transport"; snapshot > "$tmp/pre-t"
run install >/dev/null 2>&1 && bad "installed over a transport.conf that is not add1bc21"
snapshot | diff "$tmp/pre-t" - >/dev/null || bad "a refused install (wrong transport) changed files"
fresh_root h; cp "$repo/dante/service/transport-idlephase.conf" "$root$transport"; snapshot > "$tmp/pre-h"
run install > "$tmp/half.out" 2>&1 && bad "installed over a half-installed set"
grep -q 'not a state this installs from' "$tmp/half.out" || bad "the half-installed refusal does not say why: $(cat "$tmp/half.out")"
snapshot | diff "$tmp/pre-h" - >/dev/null || bad "a refused install (half installed) changed files"
fresh_root c; : > "$tmp/systemctl.log"
SYSTEMCTL_ACTIVE="usb16x16-dante.service usb16x16-dante-candidate.service" run install > "$tmp/cand.out" 2>&1 && bad "installed while the candidate launcher runs"
grep -q 'candidate' "$tmp/cand.out" || bad "the candidate refusal does not say why"
grep -q '^stop' "$tmp/systemctl.log" && bad "a refused install (candidate) stopped a unit"
SYSTEMCTL_ACTIVE="usb16x16-dante.service usb16x16-dante-rate.service" run install >/dev/null 2>&1 && bad "installed during a rate change"
SYSTEMCTL_ACTIVE="usb16x16-dante.service usb16x16-apply.service" run install >/dev/null 2>&1 && bad "installed during an apply"
snapshot | diff "$tmp/before.c" - >/dev/null || bad "a refused install (candidate, rate, apply) changed files"
fresh_root b
cp -R "$tmp/bundle" "$tmp/other-build"; printf 'another build\n' > "$tmp/other-build/out/usb16x16-dante-owner"
bundle=$tmp/other-build run install > "$tmp/other.out" 2>&1 && bad "installed a binary that is not the pinned build"
grep -q 'not the pinned' "$tmp/other.out" || bad "the other-build refusal does not say why"
cp -R "$tmp/bundle" "$tmp/tampered"; echo "// x" >> "$tmp/tampered/src/dante/owner/main.cpp"
bundle=$tmp/tampered run install >/dev/null 2>&1 && bad "a tampered bundle (source) was installed"
cp -R "$tmp/bundle" "$tmp/tampered2"; echo "IDLE_PHASE_96000=0" >> "$tmp/tampered2/service/transport-idlephase.conf"
bundle=$tmp/tampered2 run install >/dev/null 2>&1 && bad "a tampered bundle (transport.conf) was installed"
cp -R "$tmp/bundle" "$tmp/nobuild"; rm -rf "$tmp/nobuild/out"
bundle=$tmp/nobuild run install > "$tmp/nobuild.out" 2>&1 && bad "installed with nothing built"
grep -q 'build-owner-idlephase.sh first' "$tmp/nobuild.out" || bad "the not-built refusal does not say to build"
snapshot | diff "$tmp/before.b" - >/dev/null || bad "a refused install (bundle) changed files"
fresh_root g; run rollback >/dev/null 2>&1 && bad "rolled back a unit that was never installed"
snapshot | diff "$tmp/before.g" - >/dev/null || bad "a refused rollback (never installed) changed files"
fresh_root k; run install >/dev/null 2>&1 || bad "install (for the kept-copy case) failed"
echo "# changed" >> "$root$transport.idlephase-previous"; snapshot > "$tmp/pre-k"; : > "$tmp/systemctl.log"
run rollback > "$tmp/kept.out" 2>&1 && bad "rolled back onto a kept copy that is not add1bc21"
grep -q 'no verified' "$tmp/kept.out" || bad "the kept-copy refusal does not say why: $(cat "$tmp/kept.out")"
grep -q '^stop' "$tmp/systemctl.log" && bad "a refused rollback stopped the unit"
snapshot | diff "$tmp/pre-k" - >/dev/null || bad "a refused rollback (kept copy) changed files"
[ $fail = $before ] && ok "refused: a wrong owner, wrapper or transport.conf, a half-installed set, the candidate launcher, a rate change, an apply, another build, a tampered bundle, nothing built, a rollback with nothing kept or a changed kept copy"

# --- the build script refuses root (only where the test runs as root, as in a container)
if [ "$(id -u)" -eq 0 ]; then
  "$tmp/bundle/build-owner-idlephase.sh" >/dev/null 2>&1 && bad "the build ran as root" || ok "the build refuses to run as root"
fi

[ $fail = 0 ] && echo "test-owner-idlephase: all passed" || echo "test-owner-idlephase: FAILED"
exit $fail
