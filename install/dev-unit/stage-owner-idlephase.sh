#!/bin/bash
# stage-owner-idlephase.sh [OUT_DIR]
#
# On the Mac, from a clean checkout: make the bundle that builds and installs
# the owner with the --idle-phase option (dante/owner/idle-phase.patch, the
# candidate of 2026-11-20) in its service form on the development unit. The
# bundle holds the sources the owner is built from (dante/owner/main.cpp with
# every header it includes, dsp-core's bridge_core.cpp), the patch, the start
# wrapper that knows IDLE_PHASE and transport-idlephase.conf, the build script,
# a list of their hashes, and the installer with that list's hash written in.
# The owner only: bridge_core.cpp is unchanged, so the installed DSP runner
# (46f36659) stays. Nothing is copied anywhere: the last lines say how.
#
# The list is a repository file, install/dev-unit/owner-idlephase.sha256: a
# change to any file that goes into the bundle fails staging until the list is
# re-pinned on purpose. The installer is not in the list (it carries the list's
# hash); the binary's own hash is pinned in install-owner-idlephase.sh (OWNER_NEW).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/build/usb-aoip-owner-idlephase}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

# Every header main.cpp includes, followed through the headers: the owner's
# own directory first, then dsp-core/include (the order of the -I flags).
# The patch adds no include.
headers=()
pending=(dante/owner/main.cpp)
while [ ${#pending[@]} -gt 0 ]; do
  file=${pending[0]}; pending=("${pending[@]:1}")
  while IFS= read -r name; do
    if [ -f "$repo/dante/owner/$name" ]; then found=dante/owner/$name
    elif [ -f "$repo/dsp-core/include/$name" ]; then found=dsp-core/include/$name
    else echo "stage-owner-idlephase: $file includes \"$name\", which is in neither dante/owner nor dsp-core/include" >&2; exit 1; fi
    case " ${headers[*]:-} " in *" $found "*) continue ;; esac
    headers+=("$found"); pending+=("$found")
  done < <(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' "$repo/$file")
done

rm -rf "$out"
mkdir -p "$out/src" "$out/service"
for f in dante/owner/main.cpp "${headers[@]}" dsp-core/src/bridge_core.cpp dante/owner/idle-phase.patch; do
  mkdir -p "$out/src/$(dirname "$f")"
  cp "$repo/$f" "$out/src/$f"
done
cp "$repo/dante/service/usb16x16-dante-start-transport" "$repo/dante/service/transport-idlephase.conf" "$out/service/"
cp "$repo/install/dev-unit/build-owner-idlephase.sh" "$out/"
chmod 755 "$out/build-owner-idlephase.sh"

( cd "$out" && find build-owner-idlephase.sh service src -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$out/owner-idlephase.sha256"
sed "s|^manifest_sha256=@MANIFEST@\$|manifest_sha256=$(sha "$out/owner-idlephase.sha256")|" "$repo/install/dev-unit/install-owner-idlephase.sh" > "$out/install-owner-idlephase.sh"
chmod 755 "$out/install-owner-idlephase.sh"
grep -q '@MANIFEST@' "$out/install-owner-idlephase.sh" && { echo "the manifest hash was not written into the installer" >&2; exit 1; }

# The pinned list in the repository must be this one.
if ! cmp -s "$out/owner-idlephase.sha256" "$repo/install/dev-unit/owner-idlephase.sha256"; then
  echo "stage-owner-idlephase: the bundle is not the one install/dev-unit/owner-idlephase.sha256 pins." >&2
  diff "$repo/install/dev-unit/owner-idlephase.sha256" "$out/owner-idlephase.sha256" | sed -n 's/^[<>] /  /p' | head -8 >&2 || true
  echo "  A file that goes into it changed. If that is intended: cp $out/owner-idlephase.sha256 $repo/install/dev-unit/owner-idlephase.sha256" >&2
  exit 1
fi
COPYFILE_DISABLE=1 tar --no-xattrs -C "$(dirname "$out")" -czf "$out.tgz" "$(basename "$out")"
if python3 -c 'import sys, tarfile; sys.exit(any(n.rsplit("/", 1)[-1].startswith("._") for n in tarfile.open(sys.argv[1]).getnames()))' "$out.tgz"; then :; else
  echo "stage-owner-idlephase: the archive holds \"._\" entries; not a bundle to install" >&2; exit 1
fi
pins=$(grep -Ec '^OWNER_NEW=[0-9a-f]{64}$' "$out/install-owner-idlephase.sh" || true)
echo "stage-owner-idlephase: bundle $out ($(wc -l < "$out/owner-idlephase.sha256" | tr -d ' ') files, list $(sha "$out/owner-idlephase.sha256" | cut -c1-8)); binary pins: $pins of 1"
echo "  repository $(git -C "$repo" rev-parse --short HEAD 2>/dev/null)$(git -C "$repo" status --porcelain 2>/dev/null | grep -q . && echo ' WITH UNCOMMITTED CHANGES')"
cat <<EOF
Copy it to the unit, build there, and install (not during a measurement: the copy shares the link with the audio):
  scp $out.tgz USER@UNIT:
  ssh USER@UNIT
  tar xzf $(basename "$out").tgz && cd $(basename "$out")
  ./build-owner-idlephase.sh                 unprivileged; stops nothing; prints the hash
  ./install-owner-idlephase.sh status
  sudo ./install-owner-idlephase.sh install  after install-owner-monitor.sh; the hash must be OWNER_NEW
EOF
