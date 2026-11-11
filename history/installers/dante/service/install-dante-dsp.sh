#!/bin/bash
# Move the installed Dante service to the owner with DSP: the owner binary,
# the start wrapper, the unit that uses it, and (only if there is none) the
# configuration file. Statime, the plugin, the ALSA and clock configs, the
# service user, its state and the sudo rule are not touched. Run with sudo
# from ~/usb-16x16-work/dante-mode/service/.
#
#   sudo ./install-dante-dsp.sh             install
#   sudo ./install-dante-dsp.sh rollback    put back the owner and unit this replaced
#
# Verifies every source against its pinned hash and the installed owner and
# unit against the ones this is meant to replace, stops the service, keeps
# both under $libexec/before-dsp/, installs, starts, and checks the endpoint
# is up and linked to its clock; if it is not up after 30 s the previous
# owner and unit are put back and started. As installed the service runs
# direct with the level meters on (owner.conf.default); an owner.conf already
# there is kept.
#
# 2026-10-11: owner 62879558 (preset, live coefficients, meter tap, the
# capture-fault fix), unit 9f5289dd, wrapper 1f83825b.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
base=$(dirname "$script_dir")
libexec=/usr/local/libexec/usb16x16-dante
conf_dir=/etc/usb16x16/dante
keep=$libexec/before-dsp
unit=usb16x16-dante.service
unit_path=/etc/systemd/system/$unit
owner_path=$libexec/usb16x16-dante-owner
wrapper_path=$libexec/usb16x16-dante-start
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

new_owner=6287955840f747cdb70f3bc43b1ee26e79ca229f930e4a2534e85d91a4cb41a0
old_owner=e392dd7198e18a09dcd8d16b159a8c87d6536fd6e7e22d4dd643c043070dcf6d
old_unit=4c27c544e08f5ac49ab365852f8600f96fe488df48b85f7a39c390c98a4e87b0
# source, sha256
manifest="$base/owner/usb16x16-dante-owner-dspmeter|$new_owner
$script_dir/usb16x16-dante-start|1f83825b9a1b98671e10f75f5a80a1d0f4676e5e5792997a5b2e1d7d2927e4e7
$script_dir/usb16x16-dante-dsp.service|9f5289dd3fbbdd84611c3186d46851c398e925faf0bebd928a0a4a8d441643a9
$script_dir/owner.conf.default|cb022708e108f2cd1c86acdaeccf743a32a43e0364c128734fd9286baf7bb364"

up() {   # start and wait until the unit is active and has stayed so; 0 when it is
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl start "$unit" || return 1
  for _ in $(seq 1 30); do
    sleep 1
    [ "$(systemctl is-active "$unit")" = active ] || continue
    journalctl -u "$unit" --no-pager -o cat _SYSTEMD_INVOCATION_ID="$(systemctl show "$unit" -p InvocationID --value)" 2>/dev/null |
      grep -q '^NETSTART capture=RUNNING playback=RUNNING' && return 0
  done
  return 1
}

put_back() {
  systemctl stop "$unit" 2>/dev/null || true
  install -o root -g root -m 755 "$keep/usb16x16-dante-owner" "$owner_path"
  install -o root -g root -m 644 "$keep/$unit" "$unit_path"
  rm -f "$wrapper_path"
  systemctl daemon-reload
  echo "put back owner $(sha256_of "$owner_path" | cut -c1-8) and unit $(sha256_of "$unit_path" | cut -c1-8); kept $conf_dir/owner.conf"
}

if [ "$(systemctl is-active usb16x16-dante-candidate.service 2>/dev/null)" = active ]; then
  echo "usb16x16-dante-candidate is running; stop it first (sudo usb16x16-dante-candidate stop)" >&2
  exit 5
fi

if [ "${1:-}" = rollback ]; then
  [ -f "$keep/usb16x16-dante-owner" ] && [ -f "$keep/$unit" ] || { echo "nothing kept in $keep" >&2; exit 3; }
  put_back
  if up; then echo "$unit is active on the previous owner"; else echo "$unit did not come up; journalctl -u $unit" >&2; exit 6; fi
  exit 0
fi

while IFS='|' read -r source expected; do
  [ -r "$source" ] || { echo "missing source: $source" >&2; exit 3; }
  [ "$(sha256_of "$source")" = "$expected" ] || { echo "hash mismatch: $source" >&2; exit 4; }
done <<< "$manifest"
bash -n "$script_dir/usb16x16-dante-start"

current_owner=$(sha256_of "$owner_path")
current_unit=$(sha256_of "$unit_path")
if [ "$current_owner" = "$new_owner" ] && [ "$current_unit" = "9f5289dd3fbbdd84611c3186d46851c398e925faf0bebd928a0a4a8d441643a9" ] && [ -x "$wrapper_path" ] && [ "$(sha256_of "$wrapper_path")" = "1f83825b9a1b98671e10f75f5a80a1d0f4676e5e5792997a5b2e1d7d2927e4e7" ]; then
  echo "already installed"
  exit 0
fi
[ "$current_owner" = "$old_owner" ] || { echo "the installed owner is $(echo "$current_owner" | cut -c1-8), not the e392dd71 this replaces; refusing" >&2; exit 4; }
[ "$current_unit" = "$old_unit" ] || { echo "the installed unit is $(echo "$current_unit" | cut -c1-8), not the 4c27c544 this replaces; refusing" >&2; exit 4; }

systemctl stop "$unit"
install -d -o root -g root -m 755 "$keep"
install -o root -g root -m 755 "$owner_path" "$keep/usb16x16-dante-owner"
install -o root -g root -m 644 "$unit_path" "$keep/$unit"

install -o root -g root -m 755 "$base/owner/usb16x16-dante-owner-dspmeter" "$owner_path.new"
mv -f "$owner_path.new" "$owner_path"
install -o root -g root -m 755 "$script_dir/usb16x16-dante-start" "$wrapper_path"
install -o root -g root -m 644 "$script_dir/usb16x16-dante-dsp.service" "$unit_path"
if [ -e "$conf_dir/owner.conf" ]; then
  echo "kept the $conf_dir/owner.conf already there"
else
  install -o root -g root -m 644 "$script_dir/owner.conf.default" "$conf_dir/owner.conf"
  echo "installed $conf_dir/owner.conf (direct, meters on)"
fi
systemctl daemon-reload
echo "installed owner $(sha256_of "$owner_path" | cut -c1-8), wrapper, unit $(sha256_of "$unit_path" | cut -c1-8); kept the previous owner and unit in $keep"
echo "command line: $("$wrapper_path" --print | tr '\n' ' ')"

if up; then
  echo "$unit is active"
else
  echo "$unit did not come up within 30 s; putting the previous owner and unit back" >&2
  journalctl -u "$unit" --no-pager -o cat -n 8 >&2 || true
  put_back
  if up; then echo "$unit is active on the previous owner" >&2; else echo "and the previous one did not come up either; journalctl -u $unit" >&2; fi
  exit 6
fi
