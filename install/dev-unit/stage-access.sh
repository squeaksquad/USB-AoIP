#!/bin/bash
# stage-access.sh [OUT_DIR]
#
# On the Mac, from a clean checkout: make the bundle install-access.sh
# installs on a unit built by the old chain. The bundle is the repository's
# own files (the development unit's values are the ones they carry; the
# render test proves a render with those values is byte for byte these
# files), a list of their hashes, and the installer with that list's hash
# written in. Nothing is copied anywhere: the last lines say how.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/build/usb-aoip-access}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

rm -rf "$out"
mkdir -p "$out/bin" "$out/units" "$out/web-ui/compiler"
cp "$repo/web-control/usb16x16-web" "$repo/web-control/usb16x16-apply" "$out/bin/"
cp "$repo/web-control/usb16x16-web.service" "$repo/web-control/usb16x16-apply.path" "$repo/web-control/usb16x16-apply.service" "$out/units/"
for f in "$repo"/web-ui/index.html "$repo"/web-ui/style.css "$repo"/web-ui/*.mjs; do
  case "$f" in *.test.mjs) continue ;; esac
  cp "$f" "$out/web-ui/"
done
for f in compile bridge-artifact coefficients; do cp "$repo/dsp-compiler/$f.mjs" "$out/web-ui/compiler/"; done

( cd "$out" && find bin units web-ui -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$out/access.sha256"
sed "s|^manifest_sha256=@MANIFEST@\$|manifest_sha256=$(sha "$out/access.sha256")|" "$repo/install/dev-unit/install-access.sh" > "$out/install-access.sh"
chmod 755 "$out/install-access.sh"
grep -q '@MANIFEST@' "$out/install-access.sh" && { echo "the manifest hash was not written into the installer" >&2; exit 1; }

# The pinned list in the repository must be this one: a change to any file in
# the bundle is a change to what gets installed, and has to be made on purpose.
if ! cmp -s "$out/access.sha256" "$repo/install/dev-unit/access.sha256"; then
  echo "stage-access: the bundle is not the one install/dev-unit/access.sha256 pins." >&2
  echo "  A file that goes into it changed. If that is intended: cp $out/access.sha256 $repo/install/dev-unit/access.sha256" >&2
  exit 1
fi
tar -C "$(dirname "$out")" -czf "$out.tgz" "$(basename "$out")"
echo "stage-access: bundle $out ($(wc -l < "$out/access.sha256" | tr -d ' ') files, list $(sha "$out/access.sha256" | cut -c1-8))"
echo "  repository $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)$(git -C "$repo" status --porcelain 2>/dev/null | grep -q . && echo ' WITH UNCOMMITTED CHANGES')"
cat <<EOF
Copy it to the unit and install (not during a measurement: the copy shares the link with the audio):
  scp $out.tgz USER@UNIT:
  ssh USER@UNIT
  tar xzf $(basename "$out").tgz && cd $(basename "$out")
  ./install-access.sh status
  sudo ./install-access.sh install
EOF
