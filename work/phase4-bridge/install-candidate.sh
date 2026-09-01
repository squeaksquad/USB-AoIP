#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi
if [ "$#" -ne 2 ]; then
  echo "usage: $0 BRIDGE_BINARY CANDIDATE_WRAPPER" >&2
  exit 2
fi

bridge_source=$1
wrapper_source=$2
bridge_destination=/usr/local/libexec/usb16x16-rt-bridge
wrapper_destination=/usr/local/sbin/run-phase4-candidate-safe.sh
sudoers_destination=/etc/sudoers.d/usb16x16-phase4
expected_bridge_sha256=ca2d0c7b4babbfcf2ffe37b0170f24f34407ae78514f9894076098d0faeb1adb
expected_wrapper_sha256=9732d9a4bc0209d184c265aa8f8875a8a8cbbe45a8961ff7c260bf5b34d0c91f

if [ "$(sha256sum "$bridge_source" | awk '{print $1}')" != "$expected_bridge_sha256" ]; then
  echo "bridge source hash mismatch" >&2
  exit 3
fi
if [ "$(sha256sum "$wrapper_source" | awk '{print $1}')" != "$expected_wrapper_sha256" ]; then
  echo "wrapper source hash mismatch" >&2
  exit 4
fi

sudoers_temporary=$(mktemp /tmp/usb16x16-phase4-sudoers.XXXXXX)
trap 'rm -f "$sudoers_temporary"' EXIT HUP INT TERM
cat > "$sudoers_temporary" <<'EOF'
bdimaio ALL=(root) NOPASSWD: /usr/local/sbin/run-phase4-candidate-safe.sh
EOF
/usr/sbin/visudo -cf "$sudoers_temporary"

install -d -o root -g root -m 755 /usr/local/libexec
install -o root -g root -m 755 "$bridge_source" "$bridge_destination"
install -o root -g root -m 755 "$wrapper_source" "$wrapper_destination"
install -o root -g root -m 440 "$sudoers_temporary" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination"

echo "installed $bridge_destination"
echo "installed $wrapper_destination"
echo "installed $sudoers_destination"
