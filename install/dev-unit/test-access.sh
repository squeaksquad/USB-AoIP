#!/bin/bash
# What can be checked of install-access.sh without a Pi: against a directory
# standing in for /, holding the files the development unit runs today (taken
# from the tag layout-2026-11-01), with systemctl replaced by a recorder.
#   - the bundle stages, and is the one access.sha256 pins;
#   - install replaces the five files and the page, keeps the old ones,
#     makes the inbox, the state directory and the login file, and never
#     touches the audio service;
#   - a second install does nothing; rollback restores every byte;
#   - a wrong starting point, a tampered bundle and a running operation are refused.
# Run: bash install/dev-unit/test-access.sh   (needs the tag: a full clone)
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/usb-aoip-access.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
tag=layout-2026-11-01
git -C "$repo" rev-parse -q --verify "$tag^{commit}" >/dev/null || { echo "SKIP: the tag $tag is not in this clone (fetch tags)"; exit 0; }

bash "$repo/install/dev-unit/stage-access.sh" "$tmp/bundle" >/dev/null || bad "staging failed (is access.sha256 current?)"
[ -x "$tmp/bundle/install-access.sh" ] || { echo "test-access: FAILED"; exit 1; }
ok "the bundle stages and is the pinned one"

work=/home/bdimaio/usb-16x16-work
fresh_root() {   # the development unit as the old chain left it
  root=$tmp/root.$1; rm -rf "$root"
  mkdir -p "$root/usr/local/bin" "$root/etc/systemd/system" "$root$work/web-ui/compiler" "$root$work/web-apply"
  git -C "$repo" show "$tag:work/web-control/usb16x16-web"   > "$root/usr/local/bin/usb16x16-web"
  git -C "$repo" show "$tag:work/web-control/usb16x16-apply" > "$root/usr/local/bin/usb16x16-apply"
  for u in usb16x16-web.service usb16x16-apply.path usb16x16-apply.service; do
    git -C "$repo" show "$tag:work/web-control/$u" > "$root/etc/systemd/system/$u"
  done
  for f in index.html style.css app.mjs backend.mjs; do git -C "$repo" show "$tag:work/web-ui/$f" > "$root$work/web-ui/$f"; done
  git -C "$repo" show "$tag:work/dsp-compiler/compile.mjs" > "$root$work/web-ui/compiler/compile.mjs"
  echo "someone:pbkdf2_sha256\$210000\$00\$00" > "$root$work/web-auth"
  ( cd "$root" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/before.$1"
  : > "$tmp/systemctl.log"
}
cat > "$tmp/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
case "$1" in is-active) echo "${SYSTEMCTL_ACTIVE:-inactive}" ;; esac
exit 0
STUB
chmod 755 "$tmp/systemctl"
run() { USB_AOIP_TEST_ROOT=$root USB_AOIP_TEST_SYSTEMCTL=$tmp/systemctl USB_AOIP_TEST_SETTLE=0 SYSTEMCTL_LOG=$tmp/systemctl.log "$tmp/bundle/install-access.sh" "$@"; }
new_of() { sed -n "s|^\([0-9a-f]\{64\}\)  $1\$|\1|p" "$tmp/bundle/access.sha256"; }

# --- install
fresh_root a
before=$fail
run install > "$tmp/install.out" 2>&1 || { bad "install failed: $(tail -3 "$tmp/install.out")"; }
for pair in "bin/usb16x16-web|/usr/local/bin/usb16x16-web" "bin/usb16x16-apply|/usr/local/bin/usb16x16-apply" \
            "units/usb16x16-web.service|/etc/systemd/system/usb16x16-web.service" "units/usb16x16-apply.path|/etc/systemd/system/usb16x16-apply.path" \
            "units/usb16x16-apply.service|/etc/systemd/system/usb16x16-apply.service"; do
  [ "$(sha "$root${pair#*|}")" = "$(new_of "${pair%|*}")" ] || bad "install: ${pair#*|} is not the new file"
  [ -f "$root${pair#*|}.pre-access" ] || bad "install: ${pair#*|} was not kept"
done
cmp -s "$root$work/web-ui/app.mjs" "$repo/web-ui/app.mjs" || bad "install: the page is not the new one"
cmp -s "$root$work/web-ui/compiler/coefficients.mjs" "$repo/dsp-compiler/coefficients.mjs" || bad "install: the compiler modules are not in the page"
[ -d "$root$work/web-ui.pre-access" ] || bad "install: the old page was not kept"
[ -d "$root/var/spool/usb-aoip/inbox" ] && [ -d "$root/var/lib/usb16x16-apply" ] || bad "install: inbox or state directory missing"
case "$(ls -ld "$root/var/spool/usb-aoip/inbox" | cut -c1-10)" in drwx-wx--T) ;; *) bad "install: the inbox is $(ls -ld "$root/var/spool/usb-aoip/inbox" | cut -c1-10), not 1730" ;; esac
cmp -s "$root/etc/usb-aoip/web-auth" "$root$work/web-auth" || bad "install: the logins were not copied"
[ -f "$root$work/web-auth" ] || bad "install: the old login file was removed"
grep -Eq 'usb16x16-dante\.service|usb16x16-statime|usb-16x16\.service' <(grep -Ev '^is-active' "$tmp/systemctl.log") && bad "install: it acted on an audio unit: $(grep -Ev '^is-active' "$tmp/systemctl.log" | tr '\n' ';')"
grep -q '^restart usb16x16-web.service' "$tmp/systemctl.log" || bad "install: the web service was not restarted"
grep -q '^daemon-reload' "$tmp/systemctl.log" || bad "install: no daemon-reload"
[ $fail = $before ] && ok "install: five files and the page replaced and kept, inbox 1730, state, logins copied, no audio unit touched"

# --- again, then rollback
before=$fail
run install > "$tmp/again.out" 2>&1; grep -q 'already installed' "$tmp/again.out" || bad "a second install did not say it was already installed"
run rollback > "$tmp/rollback.out" 2>&1 || bad "rollback failed: $(tail -3 "$tmp/rollback.out")"
( cd "$root" && find . -type f | LC_ALL=C sort | grep -Ev '^\./(etc/usb-aoip|var/)' | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/after.a"
diff "$tmp/before.a" "$tmp/after.a" >/dev/null || bad "rollback: not every file is back as it was: $(diff "$tmp/before.a" "$tmp/after.a" | head -4 | tr '\n' ' ')"
[ ! -e "$root$work/web-ui.pre-access" ] || bad "rollback: the kept page is still there"
run install >/dev/null 2>&1 || bad "install after a rollback failed"
[ $fail = $before ] && ok "a second install does nothing; rollback restores every byte; install works again after it"

# --- a unit that already has the first bundle (web 1.7.0 e7f6ba5a) is updated in place
before=$fail
fresh_root u
run install >/dev/null 2>&1 || bad "update: the first install failed"
git -C "$repo" show 639dff7:web-control/usb16x16-web > "$root/usr/local/bin/usb16x16-web"
run status > "$tmp/status.u" 2>&1; grep -q 'usb16x16-web  *earlier bundle (e7f6ba5a)' "$tmp/status.u" || bad "update: status does not call 1.7.0 an earlier bundle: $(grep usb16x16-web "$tmp/status.u" | head -1)"
kept_before=$(sha "$root/usr/local/bin/usb16x16-web.pre-access")
run install > "$tmp/update.out" 2>&1 || bad "update: install over the first bundle failed: $(tail -2 "$tmp/update.out")"
[ "$(sha "$root/usr/local/bin/usb16x16-web")" = "$(new_of bin/usb16x16-web)" ] || bad "update: the web service is not the new one"
[ "$(sha "$root/usr/local/bin/usb16x16-web.pre-access")" = "$kept_before" ] || bad "update: the kept copy of the old chain's file was replaced"
[ "$(sha "$root/usr/local/bin/usb16x16-web.pre-access" | cut -c1-8)" = 6b98e7cf ] || bad "update: the kept copy is not the old chain's 6b98e7cf"
find "$root" -name '*.access-undo' | grep -q . && bad "update: undo copies were left behind"
run rollback >/dev/null 2>&1 || bad "update: rollback failed"
( cd "$root" && find . -type f | LC_ALL=C sort | grep -Ev '^\./(etc/usb-aoip|var/)' | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/after.u"
diff "$tmp/before.u" "$tmp/after.u" >/dev/null || bad "update: rollback did not return to the old chain's files"
# a file that is neither the old chain's, an earlier bundle's nor the new one is refused
fresh_root v; run install >/dev/null 2>&1; echo "# local edit" >> "$root/usr/local/bin/usb16x16-web"
run install >/dev/null 2>&1 && bad "update: installed over a locally edited file"
[ $fail = $before ] && ok "a unit on the first bundle is updated in place; its kept copies stay the old chain's and rollback goes all the way back"

# --- a unit whose five files are already the bundle's but whose page is an earlier one
#     (the development unit on web 1.7.2 with the page of 94b3d79) takes the page alone
before=$fail
fresh_root p
run install >/dev/null 2>&1 || bad "page: the first install failed"
rm -rf "$root$work/web-ui"; mkdir -p "$root$work/web-ui/compiler"
git -C "$repo" archive 94b3d79 web-ui | tar -x -C "$root$work" --exclude='*.test.mjs' --exclude=README.md --exclude=stage-page.sh
# In the repository web-ui/compiler holds links into dsp-compiler; on a unit they are the files.
for f in compile bridge-artifact coefficients; do rm -f "$root$work/web-ui/compiler/$f.mjs"; git -C "$repo" show "94b3d79:dsp-compiler/$f.mjs" > "$root$work/web-ui/compiler/$f.mjs"; done
cmp -s "$root$work/web-ui/app.mjs" "$repo/web-ui/app.mjs" && bad "page: the earlier page is the same as this one; the case tests nothing"
web_before=$(sha "$root/usr/local/bin/usb16x16-web")
run install > "$tmp/page.out" 2>&1 || bad "page: install over an earlier page failed: $(tail -2 "$tmp/page.out")"
grep -q 'already installed' "$tmp/page.out" && bad "page: an earlier page was called already installed"
( cd "$tmp/bundle/web-ui" && find . -type f ) | while read -r f; do cmp -s "$tmp/bundle/web-ui/$f" "$root$work/web-ui/$f" || exit 1; done || bad "page: not every page file is the bundle's"
[ "$(sha "$root/usr/local/bin/usb16x16-web")" = "$web_before" ] || bad "page: the web service changed"
[ "$(sha "$root/usr/local/bin/usb16x16-web.pre-access" | cut -c1-8)" = 6b98e7cf ] || bad "page: the kept copy is not the old chain's 6b98e7cf"
find "$root" -name '*.access-undo' | grep -q . && bad "page: undo copies were left behind"
run rollback >/dev/null 2>&1 || bad "page: rollback failed"
( cd "$root" && find . -type f | LC_ALL=C sort | grep -Ev '^\./(etc/usb-aoip|var/)' | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/after.p"
diff "$tmp/before.p" "$tmp/after.p" >/dev/null || bad "page: rollback did not return to the old chain's files"
[ $fail = $before ] && ok "a unit already on the bundle's five files takes a newer page alone; its kept copies stay the old chain's and rollback goes all the way back"

# --- the development unit as it is since 2026-11-17: web 1.7.2 (5b374f74), applier 1.9.0
#     (32b13a72) and the phase 1 page, all from ae67492. The bundle's web service and applier
#     are newer (the System actions): both are replaced, with the page, in place.
before=$fail
fresh_root s
run install >/dev/null 2>&1 || bad "actions: the first install failed"
prev=ae67492
git -C "$repo" show $prev:web-control/usb16x16-web   > "$root/usr/local/bin/usb16x16-web"
git -C "$repo" show $prev:web-control/usb16x16-apply > "$root/usr/local/bin/usb16x16-apply"
[ "$(sha "$root/usr/local/bin/usb16x16-web" | cut -c1-8)" = 5b374f74 ] || bad "actions: $prev's web service is not 5b374f74"
[ "$(sha "$root/usr/local/bin/usb16x16-apply" | cut -c1-8)" = 32b13a72 ] || bad "actions: $prev's applier is not 32b13a72"
rm -rf "$root$work/web-ui"; mkdir -p "$root$work/web-ui/compiler"
git -C "$repo" archive $prev web-ui | tar -x -C "$root$work" --exclude='*.test.mjs' --exclude=README.md --exclude=stage-page.sh
for f in compile bridge-artifact coefficients; do rm -f "$root$work/web-ui/compiler/$f.mjs"; git -C "$repo" show "$prev:dsp-compiler/$f.mjs" > "$root$work/web-ui/compiler/$f.mjs"; done
[ -e "$root$work/web-ui/actions.mjs" ] && bad "actions: the earlier page already has actions.mjs; the case tests nothing"
run status > "$tmp/status.s" 2>&1
grep -q 'usb16x16-web  *earlier bundle (5b374f74)' "$tmp/status.s" || bad "actions: status does not call web 1.7.2 an earlier bundle: $(grep 'bin/usb16x16-web' "$tmp/status.s" | head -1)"
grep -q 'usb16x16-apply  *earlier bundle (32b13a72)' "$tmp/status.s" || bad "actions: status does not call applier 1.9.0 an earlier bundle: $(grep 'bin/usb16x16-apply' "$tmp/status.s" | head -1)"
: > "$tmp/systemctl.log"
run install > "$tmp/actions.out" 2>&1 || bad "actions: install over web 1.7.2 and applier 1.9.0 failed: $(tail -2 "$tmp/actions.out")"
[ "$(sha "$root/usr/local/bin/usb16x16-web")" = "$(new_of bin/usb16x16-web)" ] || bad "actions: the web service is not the new one"
[ "$(sha "$root/usr/local/bin/usb16x16-apply")" = "$(new_of bin/usb16x16-apply)" ] || bad "actions: the applier is not the new one"
grep -q '^VERSION = "1.9.0"' "$root/usr/local/bin/usb16x16-web" || bad "actions: the installed web service is not 1.9.0"
grep -q '^VERSION = "1.11.0"' "$root/usr/local/bin/usb16x16-apply" || bad "actions: the installed applier is not 1.11.0"
cmp -s "$root$work/web-ui/actions.mjs" "$repo/web-ui/actions.mjs" || bad "actions: actions.mjs is not in the page"
( cd "$tmp/bundle/web-ui" && find . -type f ) | while read -r f; do cmp -s "$tmp/bundle/web-ui/$f" "$root$work/web-ui/$f" || exit 1; done || bad "actions: not every page file is the bundle's"
[ "$(sha "$root/usr/local/bin/usb16x16-web.pre-access" | cut -c1-8)" = 6b98e7cf ] || bad "actions: the kept web service is not the old chain's 6b98e7cf"
[ "$(sha "$root/usr/local/bin/usb16x16-apply.pre-access" | cut -c1-8)" = 347a7062 ] || bad "actions: the kept applier is not the old chain's 347a7062"
find "$root" -name '*.access-undo' | grep -q . && bad "actions: undo copies were left behind"
grep -Eq 'usb16x16-dante\.service|usb16x16-statime|usb-16x16\.service' <(grep -Ev '^is-active' "$tmp/systemctl.log") && bad "actions: it acted on an audio unit"
run install > "$tmp/actions2.out" 2>&1; grep -q 'already installed' "$tmp/actions2.out" || bad "actions: a second install did not say it was already installed"
run rollback >/dev/null 2>&1 || bad "actions: rollback failed"
( cd "$root" && find . -type f | LC_ALL=C sort | grep -Ev '^\./(etc/usb-aoip|var/)' | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/after.s"
diff "$tmp/before.s" "$tmp/after.s" >/dev/null || bad "actions: rollback did not return to the old chain's files"
[ $fail = $before ] && ok "a unit on web 1.7.2, applier 1.9.0 and the phase 1 page takes the bundle's web service, applier and page; kept copies stay the old chain's; rollback goes all the way back"

# --- the development unit as phase 2 left it (2026-11-17): web 1.8.0 (956c8569), applier 1.10.0
#     (d8a97b2c), its web unit (c908894d) and the phase 2 page, all from d05d402. The bundle's web
#     service, applier and web unit are newer (the monitor block): all three are replaced in place.
before=$fail
fresh_root m
run install >/dev/null 2>&1 || bad "monitor: the first install failed"
prev=d05d402
git -C "$repo" show $prev:web-control/usb16x16-web         > "$root/usr/local/bin/usb16x16-web"
git -C "$repo" show $prev:web-control/usb16x16-apply       > "$root/usr/local/bin/usb16x16-apply"
git -C "$repo" show $prev:web-control/usb16x16-web.service > "$root/etc/systemd/system/usb16x16-web.service"
[ "$(sha "$root/usr/local/bin/usb16x16-web" | cut -c1-8)" = 956c8569 ] || bad "monitor: $prev's web service is not 956c8569"
[ "$(sha "$root/usr/local/bin/usb16x16-apply" | cut -c1-8)" = d8a97b2c ] || bad "monitor: $prev's applier is not d8a97b2c"
[ "$(sha "$root/etc/systemd/system/usb16x16-web.service" | cut -c1-8)" = c908894d ] || bad "monitor: $prev's web unit is not c908894d"
rm -rf "$root$work/web-ui"; mkdir -p "$root$work/web-ui/compiler"
git -C "$repo" archive $prev web-ui | tar -x -C "$root$work" --exclude='*.test.mjs' --exclude=README.md --exclude=stage-page.sh
for f in compile bridge-artifact coefficients; do rm -f "$root$work/web-ui/compiler/$f.mjs"; git -C "$repo" show "$prev:dsp-compiler/$f.mjs" > "$root$work/web-ui/compiler/$f.mjs"; done
run status > "$tmp/status.m" 2>&1
grep -q 'usb16x16-web  *earlier bundle (956c8569)' "$tmp/status.m" || bad "monitor: status does not call web 1.8.0 an earlier bundle: $(grep 'bin/usb16x16-web' "$tmp/status.m" | head -1)"
grep -q 'usb16x16-apply  *earlier bundle (d8a97b2c)' "$tmp/status.m" || bad "monitor: status does not call applier 1.10.0 an earlier bundle: $(grep 'bin/usb16x16-apply' "$tmp/status.m" | head -1)"
grep -q 'usb16x16-web.service  *earlier bundle (c908894d)' "$tmp/status.m" || bad "monitor: status does not call the phase 2 web unit an earlier bundle: $(grep 'usb16x16-web.service' "$tmp/status.m" | head -1)"
: > "$tmp/systemctl.log"
run install > "$tmp/monitor.out" 2>&1 || bad "monitor: install over web 1.8.0 and applier 1.10.0 failed: $(tail -2 "$tmp/monitor.out")"
[ "$(sha "$root/usr/local/bin/usb16x16-web")" = "$(new_of bin/usb16x16-web)" ] || bad "monitor: the web service is not the new one"
[ "$(sha "$root/usr/local/bin/usb16x16-apply")" = "$(new_of bin/usb16x16-apply)" ] || bad "monitor: the applier is not the new one"
[ "$(sha "$root/etc/systemd/system/usb16x16-web.service")" = "$(new_of units/usb16x16-web.service)" ] || bad "monitor: the web unit is not the new one"
grep -q '^VERSION = "1.9.0"' "$root/usr/local/bin/usb16x16-web" || bad "monitor: the installed web service is not 1.9.0"
grep -q '^VERSION = "1.11.0"' "$root/usr/local/bin/usb16x16-apply" || bad "monitor: the installed applier is not 1.11.0"
grep -q '^RuntimeDirectory=usb-aoip-monitor$' "$root/etc/systemd/system/usb16x16-web.service" || bad "monitor: the web unit makes no monitor directory"
( cd "$tmp/bundle/web-ui" && find . -type f ) | while read -r f; do cmp -s "$tmp/bundle/web-ui/$f" "$root$work/web-ui/$f" || exit 1; done || bad "monitor: not every page file is the bundle's"
[ "$(sha "$root/usr/local/bin/usb16x16-web.pre-access" | cut -c1-8)" = 6b98e7cf ] || bad "monitor: the kept web service is not the old chain's 6b98e7cf"
[ "$(sha "$root/usr/local/bin/usb16x16-apply.pre-access" | cut -c1-8)" = 347a7062 ] || bad "monitor: the kept applier is not the old chain's 347a7062"
[ "$(sha "$root/etc/systemd/system/usb16x16-web.service.pre-access" | cut -c1-8)" = f7c7d48c ] || bad "monitor: the kept web unit is not the old chain's f7c7d48c"
find "$root" -name '*.access-undo' | grep -q . && bad "monitor: undo copies were left behind"
grep -q '^daemon-reload' "$tmp/systemctl.log" || bad "monitor: no daemon-reload for the changed unit"
grep -Eq 'usb16x16-dante\.service|usb16x16-statime|usb-16x16\.service' <(grep -Ev '^is-active' "$tmp/systemctl.log") && bad "monitor: it acted on an audio unit"
run install > "$tmp/monitor2.out" 2>&1; grep -q 'already installed' "$tmp/monitor2.out" || bad "monitor: a second install did not say it was already installed"
run rollback >/dev/null 2>&1 || bad "monitor: rollback failed"
( cd "$root" && find . -type f | LC_ALL=C sort | grep -Ev '^\./(etc/usb-aoip|var/)' | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$tmp/after.m"
diff "$tmp/before.m" "$tmp/after.m" >/dev/null || bad "monitor: rollback did not return to the old chain's files"
[ $fail = $before ] && ok "a unit on web 1.8.0, applier 1.10.0, the phase 2 web unit and page takes web 1.9.0, applier 1.11.0 and the new unit; kept copies stay the old chain's; rollback goes all the way back"

# --- refusals
before=$fail
fresh_root b; echo "# edited" >> "$root/usr/local/bin/usb16x16-apply"
run install >/dev/null 2>&1 && bad "an applier that is not 1.8.0 was replaced"
diff <(sed '$d' "$root/usr/local/bin/usb16x16-apply") <(git -C "$repo" show "$tag:work/web-control/usb16x16-apply") >/dev/null || bad "a refused install changed the applier"
[ ! -d "$root/var/spool/usb-aoip" ] || bad "a refused install made directories"
fresh_root c; : > "$root$work/web-apply/request.json"
run install >/dev/null 2>&1 && bad "installed over a waiting request"
fresh_root d
SYSTEMCTL_ACTIVE=active run install >/dev/null 2>&1 && bad "installed while an operation was running"
fresh_root e; rm "$root$work/web-auth"
run install >/dev/null 2>&1 && bad "installed with no logins to carry over"
fresh_root f; sed -i.bak 's/^User=.*/User=someoneelse/' "$root/etc/systemd/system/usb16x16-web.service"
run install >/dev/null 2>&1 && bad "installed the development unit's bundle on another unit"
fresh_root g; run rollback >/dev/null 2>&1 && bad "rolled back a unit that was never installed"
cp -R "$tmp/bundle" "$tmp/tampered"; echo "// x" >> "$tmp/tampered/web-ui/app.mjs"
USB_AOIP_TEST_ROOT=$root USB_AOIP_TEST_SYSTEMCTL=$tmp/systemctl SYSTEMCTL_LOG=$tmp/systemctl.log "$tmp/tampered/install-access.sh" install >/dev/null 2>&1 && bad "a tampered bundle was installed"
[ $fail = $before ] && ok "refused: a wrong starting point, a waiting request, a running operation, no logins, another unit, a rollback with nothing kept, a tampered bundle"

[ $fail = 0 ] && echo "test-access: all passed" || echo "test-access: FAILED"
exit $fail
