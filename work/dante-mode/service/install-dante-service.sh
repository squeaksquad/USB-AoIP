#!/bin/bash
# Install the Dante path as two services on the Pi: usb16x16-statime.service
# (the clock) and usb16x16-dante.service (the endpoint). Run once with sudo
# from ~/usb-16x16-work/dante-mode/service/, which holds this script and the
# two unit files; the binaries, the plugin and the two configs are taken from
# where they were built and measured, one directory up.
#
# Verifies every source against its pinned hash, stops a hand-started owner
# and Statime, creates the service user, installs root-owned copies, carries
# the Dante device's saved state over, and replaces the password-free rule
# for the hand-run scripts with one for these units. Does not enable or
# start anything, and does not touch usb16x16-aes67.service, the gadget or
# anything under the protected USB baseline.
#
# Rollback: sudo ./install-dante-service.sh remove
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
service_user=usb16x16-dante
libexec=/usr/local/libexec/usb16x16-dante
plugin_dir=/usr/local/lib/usb16x16-dante/alsa-plugins
conf_dir=/etc/usb16x16/dante
state_dir=/var/lib/usb16x16-dante
sudoers_destination=/etc/sudoers.d/usb16x16-dante
units="usb16x16-statime.service usb16x16-dante.service"

if [ "${1:-}" = remove ]; then
  systemctl disable --now usb16x16-dante.service usb16x16-statime.service 2>/dev/null || true
  rm -f /etc/systemd/system/usb16x16-dante.service /etc/systemd/system/usb16x16-statime.service
  rm -rf "$libexec" /usr/local/lib/usb16x16-dante "$conf_dir"
  rm -f "$sudoers_destination"
  systemctl daemon-reload
  echo "removed the units, the installed binaries, plugin and configs, and $sudoers_destination"
  echo "kept $state_dir (the Dante device's identity and subscriptions) and the user $service_user"
  exit 0
fi

# source, sha256, destination, mode. The owner is e392dd71 since 2026-10-11 (22fd2622 with the
# capture-fault fix); an existing install takes it from install-owner-update.sh instead.
manifest="$base/owner/usb16x16-dante-owner-fix|e392dd7198e18a09dcd8d16b159a8c87d6536fd6e7e22d4dd643c043070dcf6d|$libexec/usb16x16-dante-owner|755
$base/statime/target/release/statime|e195222403fc132f85de0e290580381488c211ff7744e4d10a1c7ff42d555800|$libexec/statime|755
$base/plugins/xrun-option-retry1-confirm/libasound_module_pcm_inferno.so|0ee61f2ff798abf772a0026b7a37e06da7a5cb80d454559cc2e0355fb1001330|$plugin_dir/libasound_module_pcm_inferno.so|644
$base/config/asound-inferno-owner.conf|924cfa99f69c6ab1a34488417cb9f92d30b61da4dc29fb37ca785f9d4d1feaae|$conf_dir/asound-inferno-owner.conf|644
$base/config/statime-first-run.toml|11b055dfca80e9a31357eb40a6417916c9522b26ca9f821fb6a71132e7922d71|$conf_dir/statime.toml|644
$script_dir/usb16x16-statime.service|01f1bebb07d5e9b5a7e38db628229a0d93e422b0ee388c50bd76b3168926a596|/etc/systemd/system/usb16x16-statime.service|644
$script_dir/usb16x16-dante.service|4c27c544e08f5ac49ab365852f8600f96fe488df48b85f7a39c390c98a4e87b0|/etc/systemd/system/usb16x16-dante.service|644"

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

while IFS='|' read -r source expected destination mode; do
  if [ ! -r "$source" ]; then
    echo "missing source: $source" >&2
    exit 3
  fi
  if [ "$(sha256_of "$source")" != "$expected" ]; then
    echo "hash mismatch: $source" >&2
    exit 4
  fi
done <<< "$manifest"

for unit in $units; do
  if [ "$(systemctl is-active "$unit" 2>/dev/null)" = active ]; then
    echo "$unit is active; stop it before reinstalling" >&2
    exit 5
  fi
done
if [ "$(systemctl is-active usb16x16-aes67.service 2>/dev/null)" = active ]; then
  echo "usb16x16-aes67.service is active; this install is for the Dante path, stop it first" >&2
  exit 6
fi

sudoers_temporary=$(mktemp /tmp/usb16x16-dante-sudoers.XXXXXX)
trap 'rm -f "$sudoers_temporary"' EXIT HUP INT TERM
cat > "$sudoers_temporary" <<'EOF'
# Password-free operation of the Dante services and the fresh-anchor restart
# of the gadget. Replaces the 2026-10-10 rule for the hand-run scripts in the
# operator's home directory.
bdimaio ALL=(root) NOPASSWD: /usr/bin/systemctl start usb16x16-dante, \
    /usr/bin/systemctl stop usb16x16-dante, \
    /usr/bin/systemctl restart usb16x16-dante, \
    /usr/bin/systemctl enable usb16x16-dante, \
    /usr/bin/systemctl disable usb16x16-dante, \
    /usr/bin/systemctl start usb16x16-statime, \
    /usr/bin/systemctl stop usb16x16-statime, \
    /usr/bin/systemctl restart usb16x16-statime, \
    /usr/bin/systemctl enable usb16x16-statime, \
    /usr/bin/systemctl disable usb16x16-statime, \
    /usr/bin/systemctl reset-failed usb16x16-dante, \
    /usr/bin/systemctl restart usb-16x16.service
EOF
/usr/sbin/visudo -cf "$sudoers_temporary"

# A hand-started owner and Statime hold the device and the PTP ports.
pkill -INT -x usb16x16-dante- 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x usb16x16-dante- >/dev/null || break; sleep 1; done
pkill -INT -x statime 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x statime >/dev/null || break; sleep 1; done
if pgrep -x usb16x16-dante- >/dev/null || pgrep -x statime >/dev/null; then
  echo "a hand-started owner or Statime did not stop" >&2
  exit 7
fi

if ! getent passwd "$service_user" >/dev/null; then
  useradd --system --no-create-home --home-dir "$state_dir" --shell /usr/sbin/nologin "$service_user"
  echo "created user $service_user"
fi

install -d -o root -g root -m 755 "$libexec" /usr/local/lib/usb16x16-dante "$plugin_dir" /etc/usb16x16 "$conf_dir"
while IFS='|' read -r source expected destination mode; do
  install -o root -g root -m "$mode" "$source" "$destination"
  echo "installed $destination"
done <<< "$manifest"

# The device's identity and its saved subscriptions, and the learned clock
# offset: carried over once, never overwritten.
install -d -o "$service_user" -g "$service_user" -m 750 "$state_dir"
if [ ! -e "$state_dir/inferno_aoip" ] && [ -d "$base/state/inferno_aoip" ]; then
  cp -a "$base/state/inferno_aoip" "$state_dir/"
  [ -f "$base/state/usb16x16-dante-owner.ppm" ] && cp -a "$base/state/usb16x16-dante-owner.ppm" "$state_dir/"
  echo "carried the saved state over from $base/state"
else
  echo "kept the state already in $state_dir"
fi
chown -R "$service_user":"$service_user" "$state_dir"

install -o root -g root -m 440 "$sudoers_temporary" "$sudoers_destination"
/usr/sbin/visudo -cf "$sudoers_destination"
systemctl daemon-reload

echo "installed $sudoers_destination"
echo "not enabled, not started. Next:"
echo "  sudo systemctl enable usb16x16-statime; sudo systemctl enable usb16x16-dante"
echo "  sudo systemctl start usb16x16-dante     (starts the clock with it)"
