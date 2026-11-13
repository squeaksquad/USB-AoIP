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
