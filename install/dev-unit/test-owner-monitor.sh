#!/bin/bash
# What can be checked of the owner-monitor tooling without a Pi: against a
# directory standing in for /, holding stand-ins for the owner and the runner
# the development unit runs (a test cannot make a file that hashes to c84e6a36,
# so the old and new hashes are injected, which the installer takes only with a
# stand-in root), the real start wrapper df6a1b0b from dante/service/, and
# systemctl and journalctl replaced by recorders.
#   - the bundle stages, is the one owner-monitor.sha256 pins, and a changed
#     source fails staging;
#   - install refuses while OWNER_NEW / RUNNER_NEW are empty, and the test
#     overrides are refused without a stand-in root;
#   - with test pins: install replaces both, keeps the old ones, stops and starts
#     the unit and prints the MONITOR lines; a second install does nothing;
#   - refused: a wrong starting owner, a wrong start wrapper, the candidate
#     launcher running, a binary that is not the pinned build, a tampered bundle;
#   - rollback restores every byte; it is refused while the running preset (or its
#     artifact at another rate) has a monitor section, and with nothing kept;
#   - status changes nothing.
# Run: bash install/dev-unit/test-owner-monitor.sh
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/usb-aoip-owner-monitor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

# --- staging
before=$fail
bash "$repo/install/dev-unit/stage-owner-monitor.sh" "$tmp/bundle" > "$tmp/stage.out" 2>&1 || bad "staging failed (is owner-monitor.sha256 current?): $(head -3 "$tmp/stage.out")"
[ -x "$tmp/bundle/install-owner-monitor.sh" ] || { echo "test-owner-monitor: FAILED"; exit 1; }
cmp -s "$tmp/bundle/owner-monitor.sha256" "$repo/install/dev-unit/owner-monitor.sha256" || bad "the staged list is not the repository's"
grep -q "^manifest_sha256=$(sha "$tmp/bundle/owner-monitor.sha256")\$" "$tmp/bundle/install-owner-monitor.sh" || bad "the installer does not carry the list's hash"
grep -q '^src/dante/owner/monitor_ctl.hpp$' <(cut -c67- "$tmp/bundle/owner-monitor.sha256") || bad "monitor_ctl.hpp is not in the bundle"
for f in src/dante/owner/main.cpp src/dsp-core/src/bridge_core.cpp src/dsp-core/src/dsp_offline.cpp src/dsp-core/CMakeLists.txt \
         src/dsp-core/include/usb16x16/bridge_core.hpp build-owner-monitor.sh; do
  grep -q "  $f\$" "$tmp/bundle/owner-monitor.sha256" || bad "$f is not pinned in the list"
done
listed=$(wc -l < "$tmp/bundle/owner-monitor.sha256" | tr -d ' ')
present=$(cd "$tmp/bundle" && find build-owner-monitor.sh src -type f | wc -l | tr -d ' ')
[ "$listed" = "$present" ] || bad "the list has $listed entries for $present files"
grep -Eq '^OWNER_NEW=$' "$repo/install/dev-unit/install-owner-monitor.sh" && grep -Eq '^RUNNER_NEW=$' "$repo/install/dev-unit/install-owner-monitor.sh" ||
  echo "note: OWNER_NEW / RUNNER_NEW are pinned in the repository"
# a changed source fails staging: a copy of the parts of the repository it reads
mkdir -p "$tmp/repo/install" "$tmp/repo/dante"
cp -R "$repo/install/dev-unit" "$tmp/repo/install/"; cp -R "$repo/dante/owner" "$tmp/repo/dante/"; cp -R "$repo/dsp-core" "$tmp/repo/"
bash "$tmp/repo/install/dev-unit/stage-owner-monitor.sh" "$tmp/copy-bundle" >/dev/null 2>&1 || bad "the copy of the repository does not stage as is"
echo "// changed" >> "$tmp/repo/dante/owner/servo.hpp"
bash "$tmp/repo/install/dev-unit/stage-owner-monitor.sh" "$tmp/copy-bundle" > "$tmp/changed.out" 2>&1 && bad "a changed header staged"
grep -q 'servo.hpp' "$tmp/changed.out" || bad "the refusal does not name the changed file"
cp "$repo/dante/owner/servo.hpp" "$tmp/repo/dante/owner/servo.hpp"; echo "// changed" >> "$tmp/repo/dsp-core/src/dsp_offline.cpp"
bash "$tmp/repo/install/dev-unit/stage-owner-monitor.sh" "$tmp/copy-bundle" >/dev/null 2>&1 && bad "a changed runner source staged"
[ $fail = $before ] && ok "the bundle stages ($listed files, list $(sha "$tmp/bundle/owner-monitor.sha256" | cut -c1-8)), is the pinned one, and a changed source fails staging"

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
echo "OWNER start"
echo "MONITOR following state=/run/usb-aoip-monitor/state saved=/var/lib/usb-aoip-monitor/state limits=/var/lib/usb16x16-apply/monitor-limits status=/run/usb16x16-dante/monitor.status sets=0"
echo "MONITOR first state=idle"
STUB
chmod 755 "$tmp/systemctl" "$tmp/journalctl"
printf 'old owner stand-in\n' > "$tmp/old-owner"; printf 'old runner stand-in\n' > "$tmp/old-runner"
mkdir -p "$tmp/bundle/out"
printf 'new owner stand-in\n' > "$tmp/bundle/out/usb16x16-dante-owner"; printf 'new runner stand-in\n' > "$tmp/bundle/out/usb16x16-dsp-offline"
OWNER_OLD=$(sha "$tmp/old-owner") RUNNER_OLD=$(sha "$tmp/old-runner")
OWNER_NEW=$(sha "$tmp/bundle/out/usb16x16-dante-owner") RUNNER_NEW=$(sha "$tmp/bundle/out/usb16x16-dsp-offline")
fresh_root() {   # the development unit as it is: owner c84e6a36 (stand-in), runner, start wrapper df6a1b0b
  root=$tmp/root.$1; rm -rf "$root"
  mkdir -p "$root/usr/local/libexec/usb16x16-dante" "$root/etc/usb16x16/dante" "$root/etc/usb16x16/dsp"
  cp "$tmp/old-owner" "$root/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner"
  cp "$tmp/old-runner" "$root/usr/local/libexec/usb16x16-dsp-offline"
  cp "$repo/dante/service/usb16x16-dante-start-transport" "$root/usr/local/libexec/usb16x16-dante/usb16x16-dante-start"
  printf 'METERS=1\n' > "$root/etc/usb16x16/dante/owner.conf"
  ( cd "$root" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/before.$1"
  : > "$tmp/systemctl.log"
}
snapshot() { ( cd "$root" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ); }
env_test() { env USB_AOIP_TEST_ROOT="$root" USB_AOIP_TEST_SYSTEMCTL="$tmp/systemctl" USB_AOIP_TEST_JOURNALCTL="$tmp/journalctl" \
  USB_AOIP_TEST_SETTLE=0 SYSTEMCTL_LOG="$tmp/systemctl.log" "$@"; }
run_nopins() { env_test USB_AOIP_TEST_OWNER_OLD="$OWNER_OLD" USB_AOIP_TEST_RUNNER_OLD="$RUNNER_OLD" \
  USB_AOIP_TEST_OWNER_NEW=EMPTY USB_AOIP_TEST_RUNNER_NEW=EMPTY "${bundle:-$tmp/bundle}/install-owner-monitor.sh" "$@"; }
run() { env_test USB_AOIP_TEST_OWNER_OLD="$OWNER_OLD" USB_AOIP_TEST_RUNNER_OLD="$RUNNER_OLD" \
  USB_AOIP_TEST_OWNER_NEW="$OWNER_NEW" USB_AOIP_TEST_RUNNER_NEW="$RUNNER_NEW" "${bundle:-$tmp/bundle}/install-owner-monitor.sh" "$@"; }
owner=/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner runner=/usr/local/libexec/usb16x16-dsp-offline

# --- empty pins, and the test overrides outside a test
before=$fail
fresh_root p
run_nopins install > "$tmp/nopins.out" 2>&1 && bad "installed with OWNER_NEW / RUNNER_NEW empty"
grep -q 'build-owner-monitor.sh' "$tmp/nopins.out" && grep -q 'report the two hashes' "$tmp/nopins.out" || bad "the empty-pins refusal does not say to build and report: $(cat "$tmp/nopins.out")"
snapshot | diff "$tmp/before.p" - >/dev/null || bad "a refused install changed files"
grep -q '^stop' "$tmp/systemctl.log" && bad "a refused install stopped a unit"
USB_AOIP_TEST_OWNER_NEW=$OWNER_NEW "$tmp/bundle/install-owner-monitor.sh" install > "$tmp/override.out" 2>&1 && bad "a test override was taken without a stand-in root"
grep -q 'taken only with USB_AOIP_TEST_ROOT' "$tmp/override.out" || bad "the override refusal does not say why: $(cat "$tmp/override.out")"
USB_AOIP_TEST_OWNER_OLD=$OWNER_OLD "$tmp/bundle/install-owner-monitor.sh" status > "$tmp/override2.out" 2>&1 && bad "status took a test override without a stand-in root"
[ $fail = $before ] && ok "install refuses with the binary pins empty (and says to build and report); the test overrides are refused without a stand-in root"

# --- install
before=$fail
fresh_root a
run install > "$tmp/install.out" 2>&1 || bad "install failed: $(tail -3 "$tmp/install.out")"
[ "$(sha "$root$owner")" = "$OWNER_NEW" ] || bad "install: the owner is not the new one"
[ "$(sha "$root$runner")" = "$RUNNER_NEW" ] || bad "install: the runner is not the new one"
[ "$(sha "$root$owner.pre-monitor")" = "$OWNER_OLD" ] || bad "install: the old owner was not kept"
[ "$(sha "$root$runner.pre-monitor")" = "$RUNNER_OLD" ] || bad "install: the old runner was not kept"
case "$(ls -l "$root$owner" | cut -c1-10)" in -rwxr-xr-x) ;; *) bad "install: the owner is $(ls -l "$root$owner" | cut -c1-10)" ;; esac
find "$root" -name '*.monitor-undo' -o -name '*.new' | grep -q . && bad "install: temporary copies were left behind"
grep -q "^stop usb16x16-dante.service" "$tmp/systemctl.log" || bad "install: the unit was not stopped"
grep -q "^start usb16x16-dante.service" "$tmp/systemctl.log" || bad "install: the unit was not started"
[ "$(grep -n '^stop usb16x16-dante' "$tmp/systemctl.log" | cut -d: -f1)" -lt "$(grep -n '^start usb16x16-dante' "$tmp/systemctl.log" | cut -d: -f1)" ] || bad "install: started before it stopped"
grep -Eq '^(stop|start|restart) (usb16x16-web|usb16x16-apply|usb16x16-statime|usb-16x16)' "$tmp/systemctl.log" && bad "install: it acted on another unit"
grep -q 'MONITOR following' "$tmp/install.out" && grep -q 'MONITOR first state=idle' "$tmp/install.out" || bad "install: the MONITOR lines were not printed"
grep -q 'usb16x16-dante.service is active' "$tmp/install.out" || bad "install: the unit's state was not printed"
cmp -s "$root/usr/local/libexec/usb16x16-dante/usb16x16-dante-start" "$repo/dante/service/usb16x16-dante-start-transport" || bad "install: the start wrapper changed"
run install > "$tmp/again.out" 2>&1; grep -q 'already installed' "$tmp/again.out" || bad "a second install did not say it was already installed"
[ $fail = $before ] && ok "install: owner and runner replaced and kept as *.pre-monitor, the unit stopped and started, the MONITOR lines shown; a second install does nothing"

# --- status changes nothing
before=$fail
snapshot > "$tmp/pre-status"; : > "$tmp/systemctl.log"
run status > "$tmp/status.out" 2>&1 || bad "status failed"
snapshot | diff "$tmp/pre-status" - >/dev/null || bad "status changed files"
grep -Ev '^is-active' "$tmp/systemctl.log" | grep -q . && bad "status did more than ask is-active: $(grep -Ev '^is-active' "$tmp/systemctl.log" | head -2)"
grep -q 'usb16x16-dante-owner  *new' "$tmp/status.out" && grep -q 'usb16x16-dsp-offline  *new' "$tmp/status.out" || bad "status does not call both new: $(cat "$tmp/status.out")"
grep -q 'df6a1b0b (expected)' "$tmp/status.out" || bad "status does not show the start wrapper"
fresh_root s; run_nopins status > "$tmp/status0.out" 2>&1 || bad "status with empty pins failed"
grep -q 'binary pins: owner EMPTY, runner EMPTY' "$tmp/status0.out" && grep -q 'usb16x16-dante-owner  *old' "$tmp/status0.out" || bad "status with empty pins: $(head -3 "$tmp/status0.out")"
snapshot | diff "$tmp/before.s" - >/dev/null || bad "status (empty pins) changed files"
[ $fail = $before ] && ok "status changes nothing and reports new, old, kept and the pins"

# --- rollback: refused with a monitor preset running, then restores every byte
before=$fail
root=$tmp/root.a
conf_before=$(cat "$root/etc/usb16x16/dante/owner.conf")
cp "$repo/dsp-compiler/fixtures/pinned-monitor-vector.dsp" "$root/etc/usb16x16/dsp/dante-room.dsp" 2>/dev/null ||
  printf 'usb16x16-dsp 1\nrate 48000\nmonitor 1\nend\n' > "$root/etc/usb16x16/dsp/dante-room.dsp"
printf 'METERS=1\nDSP_PRESET=/etc/usb16x16/dsp/dante-room.dsp\nDSP_SHA256=%s\nDSP_LIVE=1\n' "$(sha "$root/etc/usb16x16/dsp/dante-room.dsp")" > "$root/etc/usb16x16/dante/owner.conf"
: > "$tmp/systemctl.log"
run rollback > "$tmp/rb-monitor.out" 2>&1 && bad "rolled back with a monitor preset running"
grep -q 'monitor section' "$tmp/rb-monitor.out" && grep -q 'Direct' "$tmp/rb-monitor.out" || bad "the refusal does not say why and what to do: $(cat "$tmp/rb-monitor.out")"
grep -q '^stop' "$tmp/systemctl.log" && bad "a refused rollback stopped the unit"
[ "$(sha "$root$owner")" = "$OWNER_NEW" ] || bad "a refused rollback changed the owner"
run status > "$tmp/status-m.out" 2>&1; grep -q 'WITH a monitor section' "$tmp/status-m.out" || bad "status does not say the running preset has a monitor section"
# the running preset at 48 has none, its artifact at 96 kHz has one: the arbiter could move onto it
grep -v '^monitor' "$root/etc/usb16x16/dsp/dante-room.dsp" > "$root/etc/usb16x16/dsp/dante-room.plain" && mv "$root/etc/usb16x16/dsp/dante-room.plain" "$root/etc/usb16x16/dsp/dante-room.dsp"
printf 'usb16x16-dsp 1\nrate 96000\nmonitor 1\nend\n' > "$root/etc/usb16x16/dsp/dante-room@96000.dsp"
run rollback > "$tmp/rb-rate.out" 2>&1 && bad "rolled back with a monitor artifact at another rate of the running preset"
grep -q 'dante-room@96000.dsp' "$tmp/rb-rate.out" || bad "the refusal does not name the other rate's artifact: $(cat "$tmp/rb-rate.out")"
# a preset with no monitor section, at any rate, and one that only mentions the word: rollback proceeds
printf 'usb16x16-dsp 1\nrate 96000\npreset my monitor mix\nend\n' > "$root/etc/usb16x16/dsp/dante-room@96000.dsp"
: > "$tmp/systemctl.log"
run rollback > "$tmp/rollback.out" 2>&1 || bad "rollback failed: $(tail -3 "$tmp/rollback.out")"
rm -f "$root"/etc/usb16x16/dsp/*; printf '%s\n' "$conf_before" > "$root/etc/usb16x16/dante/owner.conf"
snapshot | diff "$tmp/before.a" - >/dev/null || bad "rollback: not every file is back as it was: $(snapshot | diff "$tmp/before.a" - | head -4 | tr '\n' ' ')"
grep -q "^stop usb16x16-dante.service" "$tmp/systemctl.log" && grep -q "^start usb16x16-dante.service" "$tmp/systemctl.log" || bad "rollback: the unit was not stopped and started"
run rollback >/dev/null 2>&1 && bad "a second rollback, with nothing kept, went ahead"
run install >/dev/null 2>&1 || bad "install after a rollback failed"
[ $fail = $before ] && ok "rollback is refused while the running preset, or its artifact at another rate, has a monitor section; otherwise it restores every byte; a second one is refused; install works again after it"

# --- refusals
before=$fail
fresh_root w; printf 'some other owner\n' > "$root$owner"; snapshot > "$tmp/pre-w"
run install > "$tmp/wrong.out" 2>&1 && bad "installed over an owner that is not c84e6a36"
grep -q 'not the .* this replaces' "$tmp/wrong.out" || bad "the wrong-owner refusal does not say why: $(cat "$tmp/wrong.out")"
snapshot | diff "$tmp/pre-w" - >/dev/null || bad "a refused install (wrong owner) changed files"
fresh_root r; printf 'some other runner\n' > "$root$runner"
run install >/dev/null 2>&1 && bad "installed over a runner that is not 4492a19c"
fresh_root x; echo "# edited" >> "$root/usr/local/libexec/usb16x16-dante/usb16x16-dante-start"
run install >/dev/null 2>&1 && bad "installed with a start wrapper that is not df6a1b0b"
fresh_root c; : > "$tmp/systemctl.log"
SYSTEMCTL_ACTIVE="usb16x16-dante.service usb16x16-dante-candidate.service" run install > "$tmp/cand.out" 2>&1 && bad "installed while the candidate launcher runs"
grep -q 'candidate' "$tmp/cand.out" || bad "the candidate refusal does not say why"
snapshot | diff "$tmp/before.c" - >/dev/null || bad "a refused install (candidate) changed files"
SYSTEMCTL_ACTIVE="usb16x16-dante.service usb16x16-dante-rate.service" run install >/dev/null 2>&1 && bad "installed during a rate change"
SYSTEMCTL_ACTIVE="usb16x16-dante.service usb16x16-apply.service" run install >/dev/null 2>&1 && bad "installed during an apply"
fresh_root b
cp -R "$tmp/bundle" "$tmp/other-build"; printf 'another build\n' > "$tmp/other-build/out/usb16x16-dante-owner"
bundle=$tmp/other-build run install > "$tmp/other.out" 2>&1 && bad "installed a binary that is not the pinned build"
grep -q 'not the pinned' "$tmp/other.out" || bad "the other-build refusal does not say why"
cp -R "$tmp/bundle" "$tmp/tampered"; echo "// x" >> "$tmp/tampered/src/dante/owner/main.cpp"
bundle=$tmp/tampered run install >/dev/null 2>&1 && bad "a tampered bundle was installed"
cp -R "$tmp/bundle" "$tmp/nobuild"; rm -rf "$tmp/nobuild/out"
bundle=$tmp/nobuild run install > "$tmp/nobuild.out" 2>&1 && bad "installed with nothing built"
grep -q 'build-owner-monitor.sh first' "$tmp/nobuild.out" || bad "the not-built refusal does not say to build"
snapshot | diff "$tmp/before.b" - >/dev/null || bad "a refused install (bundle) changed files"
fresh_root g; run rollback >/dev/null 2>&1 && bad "rolled back a unit that was never installed"
[ $fail = $before ] && ok "refused: a wrong owner, a wrong runner, a wrong start wrapper, the candidate launcher, a rate change, an apply, another build, a tampered bundle, nothing built, a rollback with nothing kept"

# --- the build script refuses root (only where the test runs as root, as in a container)
if [ "$(id -u)" -eq 0 ]; then
  "$tmp/bundle/build-owner-monitor.sh" >/dev/null 2>&1 && bad "the build ran as root" || ok "the build refuses to run as root"
fi

[ $fail = 0 ] && echo "test-owner-monitor: all passed" || echo "test-owner-monitor: FAILED"
exit $fail
