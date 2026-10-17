#!/bin/zsh
# Copy the page to the directory the Pi's web service serves
# (~/usb-16x16-work/web-ui/), with the three compiler modules as copies in its
# compiler/ (they are symlinks here). Unprivileged; run from the Mac.
#
# The running web service serves these files at once. Since 2026-10-17 the page
# sends a preset's artifacts at every rate in one request, which usb16x16-web
# 1.5.0 refuses as too large: install web 1.6.0 first
# (work/web-control/install-web-control.sh), then run this.
#
#   work/web-ui/stage-page.sh            copy, then print each file's hash on the Pi
#   work/web-ui/stage-page.sh --check    print what differs, copy nothing
set -euo pipefail
here=${0:A:h}
compiler=${here:h}/dsp-compiler
pi=bdimaio@192.168.1.201
target=usb-16x16-work/web-ui

installed=$(ssh "$pi" "cat ~/usb-16x16-work/web-control/usb16x16-web 2>/dev/null | grep -m1 '^VERSION'; grep -m1 '^VERSION' /usr/local/bin/usb16x16-web")
if [[ "${1:-}" != --check ]] && ! print -r -- "$installed" | tail -1 | grep -q '"1.6'; then
  print -r -- "the installed usb16x16-web is not 1.6.x ($installed); install it first. Nothing copied."
  exit 2
fi

page=($here/index.html $here/style.css $here/*.mjs(N))
page=(${page:#*.test.mjs})
compiler_files=($compiler/compile.mjs $compiler/bridge-artifact.mjs $compiler/coefficients.mjs)
if [[ "${1:-}" == --check ]]; then
  for f in $page; do
    local_hash=$(shasum -a 256 $f | cut -c1-8); remote=$(ssh "$pi" "sha256sum ~/$target/${f:t} 2>/dev/null | cut -c1-8")
    [[ $local_hash == $remote ]] || print -r -- "differs: ${f:t} (here $local_hash, Pi ${remote:-absent})"
  done
  for f in $compiler_files; do
    local_hash=$(shasum -a 256 $f | cut -c1-8); remote=$(ssh "$pi" "sha256sum ~/$target/compiler/${f:t} 2>/dev/null | cut -c1-8")
    [[ $local_hash == $remote ]] || print -r -- "differs: compiler/${f:t} (here $local_hash, Pi ${remote:-absent})"
  done
  exit 0
fi
scp -q $page "$pi:$target/"
scp -q $compiler_files "$pi:$target/compiler/"
ssh "$pi" "cd ~/$target && sha256sum index.html app.mjs backend.mjs compiler/*.mjs | cut -c1-8,65-"
