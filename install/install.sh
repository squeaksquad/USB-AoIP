#!/bin/bash
# install.sh: take a Raspberry Pi 5 running Raspberry Pi OS to the USB-AoIP
# point of record, from this repository alone.
#
#   sudo install/install.sh config       write /etc/usb-aoip/install.conf with detected values
#   sudo install/install.sh install      packages, kernel, builds, modules, files, services
#   sudo install/install.sh status       what is installed, and whether it is what was installed
#   sudo install/install.sh uninstall    stop and remove it (--purge: state and config too)
#   sudo install/install.sh adopt        on a unit built by the old installer chain: write the
#                                        config and manifest that describe it; change nothing else
#        install/install.sh set-password NAME   add or change a login for the web page
#
# Parts of `install`, usable alone (docs/INSTALL.md):
#        install/install.sh render --root DIR [--config FILE]   write every installed text file
#                                        under DIR instead of /; needs no root, touches nothing else
#        install/install.sh build [--build-dir DIR]             fetch, verify, patch and build
#                                        Statime, the Inferno plugin, the owner and the DSP runner
#   sudo install/install.sh build-modules [KERNELVER]           build (not install) the gadget
#                                        modules with DKMS for a kernel whose headers are installed
#
# What it will not do: retune anything. The owner, the plugin, the transport
# depths and the gadget's data path are installed as the project measured
# them. Everything site-specific comes from install.conf; nothing in what it
# installs names a person, an address or a home directory.
#
# It is idempotent: run `install` again after a failure, a config change or a
# pull. Sources and patches are verified against pinned hashes
# (install/pins.sha256, install/sources.pins) and a mismatch is a refusal.
# What it builds is hashed and recorded in the manifest, not compared with
# anyone else's build.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
conf_file=/etc/usb-aoip/install.conf
state=/var/lib/usb-aoip
manifest=$state/manifest
root=            # render --root: a prefix for every installed path
libexec=/usr/local/libexec/usb16x16-dante
plugin_dir=/usr/local/lib/usb16x16-dante/alsa-plugins
dante_etc=/etc/usb16x16/dante
units=/etc/systemd/system
inbox=/var/spool/usb-aoip/inbox
apply_state=/var/lib/usb16x16-apply
auth_file=/etc/usb-aoip/web-auth
dkms_name=usb-aoip-uac2
dkms_version=1.0
with_dev_tools=0
purge=0
build_dir=

say()    { echo "usb-aoip: $*"; }
warn()   { echo "usb-aoip: WARNING: $*" >&2; }
refuse() { echo "usb-aoip: REFUSED: $*" >&2; exit 2; }
sha()    { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
need_root() { [ "$(id -u)" -eq 0 ] || refuse "run this with sudo"; }

# ---------------------------------------------------------------- config ---

conf_keys="OPERATOR_USER WEB_USER OWNER_USER WORK_DIR AUDIO_IF AUDIO_IF_SETUP MGMT_IF WEB_PORT
KEEPALIVE_TARGETS DEVICE_NAME USB_MANUFACTURER USB_SERIAL USB_VID USB_PID USB_UDC USB_RATES
DANTE_RATES DANTE_DEVICE_ID DANTE_STATE_ID KERNEL_PIN"
# Keys added after the first release of this file: absent from an older
# install.conf they take these values, which are the behaviour it had.
optional_keys="WEB_BIND= WEB_TLS=off WEB_TLS_CERT= WEB_TLS_KEY= PTP_SANDBOX=0 PTP_STATE=0"
optional_names=$(for k in $optional_keys; do printf '%s ' "${k%%=*}"; done)
clock_dir=/run/usb16x16-statime
clock_state_file=/run/usb16x16-clock/port-state
with_port_state=0

# Each value is checked against the characters its use allows, so that what
# is rendered into units, scripts and sudoers can never be more than a value.
check_key() {
  local k=$1 v=$2
  case "$k" in
    OPERATOR_USER)     [[ -z $v || $v =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ;;
    WEB_USER|OWNER_USER) [[ $v =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ;;
    WORK_DIR)          [[ $v =~ ^/[A-Za-z0-9/_.-]+$ && $v != *..* && $v != */ ]] ;;
    AUDIO_IF|MGMT_IF)  [[ $v =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] ;;
    AUDIO_IF_SETUP)    [[ $v =~ ^(none|link-local)$ ]] ;;
    WEB_PORT)          [[ $v =~ ^[0-9]{2,5}$ ]] && [ "$v" -ge 1024 ] && [ "$v" -le 65535 ] ;;
    KEEPALIVE_TARGETS) [[ -z $v || $v =~ ^[0-9a-fA-F:.]+(\ [0-9a-fA-F:.]+)*$ ]] ;;
    DEVICE_NAME)       [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,30}$ ]] ;;
    USB_MANUFACTURER)  [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,62}$ ]] ;;
    USB_SERIAL)        [[ $v =~ ^[A-Za-z0-9]{4,32}$ ]] ;;
    USB_VID|USB_PID)   [[ $v =~ ^0x[0-9a-fA-F]{4}$ ]] ;;
    USB_UDC)           [[ $v =~ ^[A-Za-z0-9_.-]+$ ]] ;;
    USB_RATES|DANTE_RATES) [[ $v =~ ^(44100|48000|88200|96000)(,(44100|48000|88200|96000)){0,3}$ ]] ;;
    DANTE_DEVICE_ID|DANTE_STATE_ID) [[ $v =~ ^[0-9a-f]{16}$ ]] ;;
    KERNEL_PIN)        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9+._-]*$ ]] ;;
    WEB_BIND)          [[ -z $v || $v =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ;;
    WEB_TLS)           [[ $v =~ ^(self-signed|provided|off)$ ]] ;;
    WEB_TLS_CERT|WEB_TLS_KEY) [[ -z $v || ( $v =~ ^/[A-Za-z0-9/_.-]+$ && $v != *..* ) ]] ;;
    PTP_SANDBOX|PTP_STATE) [[ $v =~ ^[01]$ ]] ;;
    *) return 1 ;;
  esac
}

load_conf() {
  local f=${1:-$conf_file} line k v
  [ -r "$f" ] || refuse "no config at $f; run: sudo install/install.sh config"
  for k in $conf_keys; do unset "$k"; done
  for k in $optional_keys; do printf -v "${k%%=*}" '%s' "${k#*=}"; done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || refuse "$f: not KEY=value: $line"
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    [[ " $(echo $conf_keys) $optional_names " == *" $k "* ]] || refuse "$f: unknown key $k"
    check_key "$k" "$v" || refuse "$f: $k has a value it cannot take: '$v'"
    printf -v "$k" '%s' "$v"
  done < "$f"
  for k in $conf_keys; do
    [ -n "${!k+set}" ] || refuse "$f: $k is missing (see install/install.conf.example)"
  done
  [ -n "$USB_SERIAL" ] || refuse "$f: USB_SERIAL is empty"
  [ -n "$DANTE_DEVICE_ID" ] || refuse "$f: DANTE_DEVICE_ID is empty"
  if [ "$WEB_TLS" = provided ]; then
    [ -n "$WEB_TLS_CERT" ] && [ -n "$WEB_TLS_KEY" ] || refuse "$f: WEB_TLS=provided needs WEB_TLS_CERT and WEB_TLS_KEY"
  fi
  # The shared USB clock and the arbiter both need the two lists to hold the same rates.
  [ "$(tr ',' '\n' <<<"$USB_RATES" | sort | tr '\n' ,)" = "$(tr ',' '\n' <<<"$DANTE_RATES" | sort | tr '\n' ,)" ] ||
    refuse "$f: USB_RATES and DANTE_RATES must list the same rates"
}

detect_serial() {   # UA + the last 8 hex digits of the Pi's serial number
  local s
  s=$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null || true)
  [ -n "$s" ] || s=$(sed -n 's/^Serial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | tail -1)
  s=$(printf '%s' "$s" | tr -cd '0-9a-fA-F' | tr 'a-f' 'A-F')
  [ ${#s} -ge 8 ] || return 1
  echo "UA${s: -8}"
}

detect_device_id() {   # the audio port's MAC, then 0000
  local mac
  mac=$(tr -d ':\n' < "/sys/class/net/$1/address" 2>/dev/null | tr 'A-F' 'a-f')
  [[ $mac =~ ^[0-9a-f]{12}$ ]] || return 1
  echo "${mac}0000"
}

cmd_config() {
  need_root
  [ ! -e "$conf_file" ] || refuse "$conf_file exists; edit it, or remove it to detect again"
  local audio=eth0 mgmt serial id operator udc
  [ -d /sys/class/net/eth0 ] || audio=$(ls /sys/class/net | grep -E '^(en|eth)' | head -1)
  [ -n "$audio" ] || refuse "no wired network interface found"
  if [ -d /sys/class/net/wlan0 ]; then mgmt=wlan0; else mgmt=$audio; fi
  serial=$(detect_serial) || refuse "could not read the Pi's serial number; set USB_SERIAL by hand"
  id=$(detect_device_id "$audio") || refuse "could not read $audio's MAC address; set DANTE_DEVICE_ID by hand"
  operator=${SUDO_USER:-}; [ "$operator" != root ] || operator=
  udc=$(ls /sys/class/udc 2>/dev/null | head -1); [ -n "$udc" ] || udc=1000480000.usb
  install -d -m 755 "$(dirname "$conf_file")"
  sed -e "s|^OPERATOR_USER=.*|OPERATOR_USER=$operator|" -e "s|^AUDIO_IF=.*|AUDIO_IF=$audio|" \
      -e "s|^MGMT_IF=.*|MGMT_IF=$mgmt|" -e "s|^USB_SERIAL=.*|USB_SERIAL=$serial|" \
      -e "s|^USB_UDC=.*|USB_UDC=$udc|" -e "s|^DANTE_DEVICE_ID=.*|DANTE_DEVICE_ID=$id|" \
      "$repo/install/install.conf.example" > "$conf_file"
  chmod 644 "$conf_file"
  load_conf
  say "wrote $conf_file:"
  grep -v '^#' "$conf_file" | grep -v '^$' | sed 's/^/    /'
  say "check it (the audio port above all), then: sudo install/install.sh install"
}

# ---------------------------------------------------------------- render ---
# Every installed text file is a file of this repository with the site's
# values substituted for the development unit's. With the development unit's
# values the result is byte for byte what that unit runs (install/test-render.sh
# checks it), so a fresh install differs from the measured one only by its
# own names and addresses.

rendered=()      # "path sha256" of everything put, for the manifest

site_sed() {     # the substitutions that hold in any file (perl: \b is not portable in sed)
  W=$WORK_DIR A=$AUDIO_IF M=$MGMT_IF perl -pe \
    's{/home/bdimaio/usb-16x16-work}{$ENV{W}}g; s{\beth0\b}{$ENV{A}}g; s{\bwlan0\b}{$ENV{M}}g' "$@"
}

put() {          # put MODE DEST < content      (root-owned; DEST is absolute)
  local mode=$1 dest=$root$2 tmp
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "$dest.XXXXXX")
  cat > "$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; refuse "rendering $2 produced nothing"; }
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
  rendered+=("$2 $(sha "$dest")")
}

put_file() {     # put_file MODE SRC DEST [sed args...]: SRC with the site's values
  local mode=$1 src=$repo/$2 dest=$3; shift 3
  [ -r "$src" ] || refuse "missing $src"
  # put runs in this shell (it records what it wrote), so the content comes by process substitution.
  if [ $# -gt 0 ]; then put "$mode" "$dest" < <(site_sed "$src" | sed "$@"); else put "$mode" "$dest" < <(site_sed "$src"); fi
}

put_raw() {      # put_raw MODE SRC DEST: SRC exactly (the page's modules; nothing site-specific in them)
  [ -r "$repo/$2" ] || refuse "missing $repo/$2"
  put "$1" "$3" < "$repo/$2"
}

put_keep() {     # as put_file, unless DEST exists: operator-owned settings survive a reinstall
  if [ -e "$root$3" ]; then rendered+=("$3 $(sha "$root$3")"); else put_file "$@"; fi
}

keepalive_unit() {
  local t loop=
  for t in $KEEPALIVE_TARGETS; do loop+="ping -c 1 -W 1 -I $MGMT_IF $t >/dev/null 2>\&1; "; done
  sed -e "s#^ExecStart=.*#ExecStart=/bin/bash -c 'while :; do ${loop}sleep 20; done'#" \
      "$repo/gadget/usb16x16-wlan-keepalive.service" | site_sed
}

sudoers_rule() { # the operator's password-free control of the audio services
  cat <<EOF
# Password-free operation of the Dante services and the fresh-anchor restart
# of the gadget. Replaces the 2026-10-10 rule for the hand-run scripts in the
# operator's home directory.
$OPERATOR_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start usb16x16-dante, \\
    /usr/bin/systemctl stop usb16x16-dante, \\
    /usr/bin/systemctl restart usb16x16-dante, \\
    /usr/bin/systemctl enable usb16x16-dante, \\
    /usr/bin/systemctl disable usb16x16-dante, \\
    /usr/bin/systemctl start usb16x16-statime, \\
    /usr/bin/systemctl stop usb16x16-statime, \\
    /usr/bin/systemctl restart usb16x16-statime, \\
    /usr/bin/systemctl enable usb16x16-statime, \\
    /usr/bin/systemctl disable usb16x16-statime, \\
    /usr/bin/systemctl reset-failed usb16x16-dante, \\
    /usr/bin/systemctl restart usb-16x16.service
EOF
}

render() {
  rendered=()
  local d=dante/service g=gadget w=web-control f rate_now

  # --- the network side
  # PTP_SANDBOX=1 (docs/INSTALL.md, "The clock service as an ordinary user"): Statime
  # as the audio account with two capabilities, its socket out of /tmp. Off, these
  # three files are exactly the accepted ones.
  local sock=/tmp/ptp-usrvclock ptp_unit=() ptp_toml=() ptp_asound=()
  if [ "$PTP_SANDBOX" = 1 ]; then
    sock=$clock_dir/ptp-usrvclock
    ptp_unit=(-e "s|^Type=simple\$|Type=simple\\
User=$OWNER_USER\\
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW\\
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW\\
NoNewPrivileges=yes\\
RuntimeDirectory=$(basename "$clock_dir")\\
RuntimeDirectoryMode=0750\\
ProtectSystem=strict\\
ProtectHome=yes\\
PrivateDevices=yes\\
ProtectKernelTunables=yes\\
ProtectKernelModules=yes\\
ProtectControlGroups=yes|")
    ptp_toml=(-e "s|^usrvclock-export = true\$|usrvclock-export = true\\
usrvclock-path = \"$sock\"|")
    ptp_asound=(-e "s|^\\([[:space:]]*\\)BIND_IP \\(.*\\)\$|\\1BIND_IP \\2\\
\\1CLOCK_PATH \"$sock\"|")
  fi
  # PTP_STATE=1 (docs/INSTALL.md, "Showing whether the clock has a leader"): a
  # Statime built with dante/patches/statime/0001 is told where to publish its
  # port state; the directory comes from tmpfiles.d, so it is there before any start.
  local ptp_state=() state_user=root
  if [ "$PTP_STATE" = 1 ]; then
    [ "$PTP_SANDBOX" = 1 ] && state_user=$OWNER_USER
    ptp_state=(-e "s|^ExecStart=\\(.*\\)\$|Environment=STATIME_PORT_STATE_FILE=$clock_state_file\\
ReadWritePaths=-$(dirname "$clock_state_file")\\
ExecStartPre=-/usr/bin/rm -f $clock_state_file\\
ExecStart=\\1|")
    put 644 /etc/tmpfiles.d/usb-aoip-clock.conf <<EOF
# Where the clock service publishes its PTP port state for the control page.
d $(dirname "$clock_state_file") 0755 $state_user $state_user -
EOF
  fi
  put_file 644 $d/usb16x16-statime.service              $units/usb16x16-statime.service \
    -e "s|/tmp/ptp-usrvclock|$sock|g" ${ptp_unit[@]+"${ptp_unit[@]}"} ${ptp_state[@]+"${ptp_state[@]}"}
  put_file 644 $d/usb16x16-dante-dsp-linkwait.service   $units/usb16x16-dante.service \
    -e "s|/tmp/ptp-usrvclock|$sock|g" -e "s|^User=usb16x16-dante\$|User=$OWNER_USER|" -e "s|^Group=usb16x16-dante\$|Group=$OWNER_USER|"
  put_file 644 $d/usb16x16-dante-startcheck.service     $units/usb16x16-dante-startcheck.service
  put_file 644 $d/usb16x16-dante-rate.path              $units/usb16x16-dante-rate.path
  put_file 644 $d/usb16x16-dante-rate.service           $units/usb16x16-dante-rate.service
  for f in dante statime dante-startcheck dante-rate; do
    put_file 644 $d/10-usb-aoip-$f.conf $units/usb16x16-$f.service.d/10-usb-aoip.conf -e "s|USB-AoIP|$DEVICE_NAME|g"
  done
  put 644 $units/usb16x16-dante-startcheck.service.d/20-thresholds.conf <<EOF
# The start check's thresholds as configuration (docs/INSTALL.md, "What the
# tuning assumes"). Without the file the script's own defaults apply.
[Service]
EnvironmentFile=-$dante_etc/startcheck.conf
EOF
  put_file 755 $d/usb16x16-dante-start-transport        $libexec/usb16x16-dante-start
  put_file 755 $d/usb16x16-dante-startcheck             $libexec/usb16x16-dante-startcheck
  put_keep 644 $d/transport-rate882.conf                $dante_etc/transport.conf
  put_keep 644 $d/startcheck.conf                       $dante_etc/startcheck.conf
  put_keep 644 $d/owner.conf.default                    $dante_etc/owner.conf
  # The applier moves SAMPLE_RATE with owner.conf's RATE=; a reinstall keeps the pair.
  rate_now=$(sed -n 's/^[[:space:]]*SAMPLE_RATE "\([0-9]*\)".*/\1/p' "$root$dante_etc/asound-inferno-owner.conf" 2>/dev/null | head -1 || true)
  put_file 644 dante/config/asound-inferno-owner-usb-aoip-rate882.conf $dante_etc/asound-inferno-owner.conf \
    -e "s|^\\([[:space:]]*NAME\\) \"[^\"]*\"|\\1 \"$DEVICE_NAME\"|" \
    -e "s|^\\([[:space:]]*DEVICE_ID\\) \"[^\"]*\"|\\1 \"$DANTE_DEVICE_ID\"|" \
    -e "s|^\\([[:space:]]*STATE_ID\\) \"[^\"]*\"|\\1 \"$DANTE_STATE_ID\"|" \
    -e "s|^\\([[:space:]]*SUPPORTED_SAMPLE_RATES\\) \"[^\"]*\"|\\1 \"$DANTE_RATES\"|" \
    -e "s|^\\([[:space:]]*SAMPLE_RATE\\) \"[^\"]*\"|\\1 \"${rate_now:-48000}\"|" ${ptp_asound[@]+"${ptp_asound[@]}"}
  put_file 644 dante/config/statime-first-run.toml      $dante_etc/statime.toml ${ptp_toml[@]+"${ptp_toml[@]}"}
  put_file 644 $d/90-usb16x16-eth0-carrier.conf         /etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf
  put_file 644 $d/90-usb16x16-compaction.conf           /etc/sysctl.d/90-usb16x16-compaction.conf

  # --- the USB side
  put_file 755 $g/setup-usb-aoip /usr/local/sbin/setup-usb-aoip \
    -e "s|^RATES=.*|RATES=$USB_RATES|" \
    -e "s|^UDC=.*|UDC=$USB_UDC|" \
    -e "s|0x1d6b > \"\$G/idVendor\"|$USB_VID > \"\$G/idVendor\"|" \
    -e "s|0x0104 > \"\$G/idProduct\"|$USB_PID > \"\$G/idProduct\"|" \
    -e "s|AUDDEV001 > \"\$G/strings/0x409/serialnumber\"|$USB_SERIAL > \"\$G/strings/0x409/serialnumber\"|" \
    -e "s|'Bryan DiMaio' > \"\$G/strings/0x409/manufacturer\"|'$USB_MANUFACTURER' > \"\$G/strings/0x409/manufacturer\"|" \
    -e "s|'USB-AoIP' > \"\$G/strings/0x409/product\"|'$DEVICE_NAME' > \"\$G/strings/0x409/product\"|" \
    -e "s|'USB-AoIP' > \"\$F/function_name\"|'$DEVICE_NAME' > \"\$F/function_name\"|" \
    -e "s|'USB-AoIP' > \"\$F/if_ctrl_name\"|'$DEVICE_NAME' > \"\$F/if_ctrl_name\"|"
  put_file 644 $g/usb-16x16.service                     $units/usb-16x16.service
  put_file 755 $g/stall-tuning.sh /usr/local/sbin/usb16x16-stall-tuning \
    -e "s|^usb_irq_pattern=.*|usb_irq_pattern='$USB_UDC'|"
  put_file 644 $g/usb16x16-governor.service             $units/usb16x16-governor.service
  if [ -n "$KEEPALIVE_TARGETS" ]; then
    put 644 $units/usb16x16-wlan-keepalive.service < <(keepalive_unit)
  fi

  # --- the page and its backend
  put_file 755 $w/usb16x16-web                          /usr/local/bin/usb16x16-web
  put_file 755 $w/usb16x16-apply                        /usr/local/bin/usb16x16-apply
  put_file 644 $w/usb16x16-web.service $units/usb16x16-web.service \
    -e "s|^User=.*|User=$WEB_USER|" -e "s|^Group=.*|Group=$WEB_USER|" \
    -e "s|--port 8088|--port $WEB_PORT|"
  put_file 644 $w/usb16x16-apply.path                   $units/usb16x16-apply.path
  put_file 644 $w/usb16x16-apply.service                $units/usb16x16-apply.service
  for f in "$repo"/web-ui/index.html "$repo"/web-ui/style.css "$repo"/web-ui/*.mjs; do
    case "$f" in *.test.mjs) continue ;; esac
    put_raw 644 "web-ui/$(basename "$f")" "$WORK_DIR/web-ui/$(basename "$f")"
  done
  for f in compile bridge-artifact coefficients; do
    put_raw 644 dsp-compiler/$f.mjs "$WORK_DIR/web-ui/compiler/$f.mjs"
  done

  # --- the operator's rule; development aids only when asked for
  if [ -n "$OPERATOR_USER" ]; then
    put 440 /etc/sudoers.d/usb16x16-dante < <(sudoers_rule)
    if [ "$with_dev_tools" = 1 ]; then
      put_file 755 $d/usb16x16-dante-candidate /usr/local/sbin/usb16x16-dante-candidate -e "s|^operator=.*|operator=$OPERATOR_USER|" -e "s|~bdimaio|~$OPERATOR_USER|g" -e "s|/tmp/ptp-usrvclock|$sock|g"
      put_file 755 $d/usb16x16-dante-catch     /usr/local/sbin/usb16x16-dante-catch
      put 440 /etc/sudoers.d/usb16x16-dante-candidate <<<"$OPERATOR_USER ALL=(root) NOPASSWD: /usr/local/sbin/usb16x16-dante-candidate"
      put 440 /etc/sudoers.d/usb16x16-dante-catch <<<"$OPERATOR_USER ALL=(root) NOPASSWD: /usr/local/sbin/usb16x16-dante-catch"
    fi
  fi
}

cmd_render() {
  [ -n "$root" ] || refuse "render needs --root DIR"
  load_conf "$conf_file"
  mkdir -p "$root"
  render
  printf '%s\n' "${rendered[@]}" | sort > "$root/manifest.rendered"
  say "rendered ${#rendered[@]} files under $root"
}

# ----------------------------------------------------------------- build ---

pin() { sed -n "s/^$1[[:space:]]\{1,\}//p" "$repo/install/sources.pins" | head -1; }

verify_pins() {  # every patch and source file the builds use is the pinned one
  local want path
  while read -r want path; do
    [ -n "$want" ] || continue
    [ "$(sha "$repo/$path")" = "$want" ] || refuse "$path is not the pinned file (${want:0:8}); the checkout is modified or incomplete"
  done < "$repo/install/pins.sha256"
}

as_builder() {   # run a build step unprivileged when started with sudo
  if [ "$(id -u)" -eq 0 ] && [ "${builder:-root}" != root ]; then
    runuser -u "$builder" -- env HOME="$build_dir" CARGO_HOME="$build_dir/cargo" RUSTUP_HOME="$build_dir/rustup" \
      PATH="$build_dir/cargo/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  else
    env CARGO_HOME="$build_dir/cargo" RUSTUP_HOME="$build_dir/rustup" PATH="$build_dir/cargo/bin:$PATH" "$@"
  fi
}

fetch_source() { # fetch_source NAME URL REV: a checkout at exactly REV, submodules included
  local name=$1 url=$2 rev=$3 dir=$build_dir/$1
  if [ "$(as_builder git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$rev" ]; then
    rm -rf "$dir"
    as_builder git clone --quiet "$url" "$dir"
    as_builder git -C "$dir" checkout --quiet --detach "$rev"
  fi
  as_builder git -C "$dir" reset --quiet --hard "$rev"
  as_builder git -C "$dir" submodule --quiet update --init --recursive --force
  [ "$(as_builder git -C "$dir" rev-parse HEAD)" = "$rev" ] || refuse "$name is not at $rev"
}

check_submodule() { [ "$(as_builder git -C "$build_dir/$1/$2" rev-parse HEAD)" = "$3" ] || refuse "$1 submodule $2 is not at the pinned $3"; }

install_rust() {
  local want arch url tmp
  want=$(pin rust_toolchain)
  if as_builder rustc --version 2>/dev/null | grep -q "^rustc $want "; then return; fi
  case "$(uname -m)" in aarch64) arch=aarch64-unknown-linux-gnu ;; x86_64) arch=x86_64-unknown-linux-gnu ;; *) refuse "no Rust toolchain known for $(uname -m)" ;; esac
  url=https://static.rust-lang.org/rustup/dist/$arch/rustup-init
  tmp=$build_dir/rustup-init
  say "installing Rust $want under $build_dir (rustup, minimal profile)"
  as_builder curl -fsSL --retry 2 -o "$tmp" "$url"
  as_builder curl -fsSL --retry 2 -o "$tmp.sha256" "$url.sha256"
  [ "$(sha "$tmp")" = "$(cut -c1-64 "$tmp.sha256")" ] || refuse "rustup-init does not match its published sha256"
  chmod 755 "$tmp"
  as_builder "$tmp" -y --quiet --no-modify-path --profile minimal --default-toolchain "$want"
}

cmd_build() {
  build_dir=${build_dir:-$state/build}
  local jobs=${USB_AOIP_JOBS:-2} p out=$build_dir/out
  verify_pins
  mkdir -p "$build_dir"
  if [ "$(id -u)" -eq 0 ]; then
    # The account that owns this checkout can read it; a service account often cannot
    # (home directories are 0700). Without one (a root shell) the builds run as root.
    builder=${USB_AOIP_BUILDER:-${SUDO_USER:-root}}
    getent passwd "$builder" >/dev/null || builder=root
    chown -R "$builder" "$build_dir"
  fi
  as_builder mkdir -p "$out"
  install_rust

  say "fetching Inferno and Statime at the pinned revisions"
  fetch_source inferno "$(pin inferno_url)" "$(pin inferno_rev)"
  check_submodule inferno alsa-sys-all "$(pin inferno_alsa_sys_all)"
  check_submodule inferno searchfire   "$(pin inferno_searchfire)"
  check_submodule inferno usrvclock-rs "$(pin inferno_usrvclock_rs)"
  [ "$(sha "$build_dir/inferno/Cargo.lock")" = "$(pin inferno_cargo_lock)" ] || refuse "Inferno's Cargo.lock is not the pinned one"
  fetch_source statime "$(pin statime_url)" "$(pin statime_rev)"
  check_submodule statime clock-steering     "$(pin statime_clock_steering)"
  check_submodule statime timestamped-socket "$(pin statime_timestamped_socket)"
  [ "$(sha "$build_dir/statime/Cargo.lock")" = "$(pin statime_cargo_lock)" ] || refuse "Statime's Cargo.lock is not the pinned one"

  say "applying the five Inferno patches"
  for p in "$repo"/dante/patches/000[1-5]-*.patch; do
    as_builder patch -s -p1 -F 0 -d "$build_dir/inferno" < "$p" || refuse "$(basename "$p") does not apply to the pinned Inferno"
  done

  if [ "${PTP_STATE:-0}" = 1 ] || [ "$with_port_state" = 1 ]; then
    say "applying the Statime port-state patch (PTP_STATE=1: a draft, not the measured build)"
    for p in "$repo"/dante/patches/statime/0001-*.patch; do
      as_builder patch -s -p1 -F 0 -d "$build_dir/statime" < "$p" || refuse "$(basename "$p") does not apply to the pinned Statime"
    done
  fi
  say "building Statime (several minutes on a Pi 5)"
  ( cd "$build_dir/statime" && as_builder cargo build --release --locked -j"$jobs" -p statime-linux )
  say "building the Inferno ALSA plugin"
  ( cd "$build_dir/inferno" && as_builder cargo build --release --locked -j"$jobs" -p alsa_pcm_inferno )
  # The checkouts go back to the pinned trees, so a second run starts from them.
  as_builder git -C "$build_dir/inferno" reset --quiet --hard "$(pin inferno_rev)"
  as_builder git -C "$build_dir/statime" reset --quiet --hard "$(pin statime_rev)"

  say "building the owner (the point-of-record source)"
  as_builder g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror \
    -I "$repo/dante/owner" -I "$repo/dsp-core/include" -o "$out/usb16x16-dante-owner" \
    "$repo/dante/owner/point-of-record/main.cpp" "$repo/dsp-core/src/bridge_core.cpp" -lasound -lpthread

  say "building the DSP runner"
  as_builder cmake -S "$repo/dsp-core" -B "$build_dir/dsp-core" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
  as_builder cmake --build "$build_dir/dsp-core" --target usb16x16-dsp-offline -j"$jobs" >/dev/null

  as_builder cp "$build_dir/statime/target/release/statime" "$out/statime"
  as_builder cp "$build_dir/inferno/target/release/libasound_module_pcm_inferno.so" "$out/libasound_module_pcm_inferno.so"
  as_builder cp "$build_dir/dsp-core/usb16x16-dsp-offline" "$out/usb16x16-dsp-offline"
  say "built, in $out:"
  for p in usb16x16-dante-owner statime libasound_module_pcm_inferno.so usb16x16-dsp-offline; do
    echo "    $(sha "$out/$p")  $p"
  done
}

# --------------------------------------------------------------- install ---

packages="build-essential g++ cmake pkg-config libasound2-dev alsa-utils ethtool dkms curl git patch python3 ca-certificates openssl"

preflight() {
  [ "$(uname -m)" = aarch64 ] || refuse "this is $(uname -m); the device is a 64-bit Raspberry Pi 5"
  grep -q 'Raspberry Pi 5' /proc/device-tree/model 2>/dev/null ||
    refuse "this is not a Raspberry Pi 5 ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown model)); nothing else has been tried"
  command -v apt-get >/dev/null || refuse "no apt-get: Raspberry Pi OS (Debian) is the only system this installs on"
  command -v nmcli >/dev/null || warn "NetworkManager (nmcli) not found; the carrier drop-in will have no effect"
  [ -d "/sys/class/net/$AUDIO_IF" ] || refuse "AUDIO_IF=$AUDIO_IF does not exist on this machine"
  [ -d "/sys/class/net/$MGMT_IF" ] || warn "MGMT_IF=$MGMT_IF does not exist; the page will listen on 127.0.0.1 only"
  if systemctl is-enabled --quiet usb16x16-aes67.service 2>/dev/null; then
    refuse "usb16x16-aes67.service is enabled: this unit was built by the old chain. Use 'adopt', not 'install'"
  fi
}

ensure_kernel() {
  local running base
  running=$(uname -r)
  say "installing kernel $KERNEL_PIN and its headers, and holding them"
  apt-get install -y -q "linux-image-$KERNEL_PIN" "linux-headers-$KERNEL_PIN" ||
    refuse "linux-image-$KERNEL_PIN is not in the package archive any more. The gadget patches apply to 6.18.34 through 6.18.49; set KERNEL_PIN to a release in that range that the archive has (apt-cache search linux-image-6.18), or port the patches (docs/INSTALL.md, \"Kernel upgrades\")"
  apt-mark hold "linux-image-$KERNEL_PIN" "linux-headers-$KERNEL_PIN" >/dev/null
  if [ "$running" != "$KERNEL_PIN" ]; then
    cat >&2 <<EOF
usb-aoip: STOPPED: the running kernel is $running, the unit needs $KERNEL_PIN.
  $KERNEL_PIN is now installed. Raspberry Pi OS boots the newest kernel it has, so
  the newer ones have to go before it will boot this one:
      dpkg -l 'linux-image-*rpi-2712' | grep ^ii
      sudo apt-get remove linux-image-rpi-2712 linux-headers-rpi-2712 <each newer linux-image-... and linux-headers-...>
      sudo reboot
  then run this again. (Nothing else has been changed yet.)
EOF
    exit 3
  fi
  # Refuse now, with the reason, if the patches do not apply to this kernel.
  "$repo/kernel/dkms/prepare-sources.sh" "$running" "$state/kernel-check" >/dev/null ||
    refuse "the gadget patches do not apply to kernel $running (see the message above)"
  rm -rf "$state/kernel-check"
}

ensure_udc() {   # the USB-C port in device mode
  [ -e "/sys/class/udc/$USB_UDC" ] && return
  local cfg=/boot/firmware/config.txt
  [ -w "$cfg" ] || refuse "no USB device controller $USB_UDC and no $cfg to enable it in"
  if ! grep -Eq '^[[:space:]]*dtoverlay=dwc2' "$cfg"; then
    cp -p "$cfg" "$cfg.usb-aoip-before"
    printf '\n# USB-AoIP: the USB-C port as a USB device (gadget), not a host\n[all]\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$cfg"
    say "added dtoverlay=dwc2,dr_mode=peripheral to $cfg (the old file is $cfg.usb-aoip-before)"
  fi
  cat >&2 <<EOF
usb-aoip: STOPPED: the USB device controller $USB_UDC is not there yet.
  $cfg now enables it; reboot and run this again. Power the Pi from something
  other than its USB-C port (PoE or the GPIO header): that port becomes the
  connection to the computer.
EOF
  exit 3
}

ensure_users() {
  getent passwd "$OWNER_USER" >/dev/null ||
    useradd --system --no-create-home --home-dir /var/lib/usb16x16-dante --shell /usr/sbin/nologin "$OWNER_USER"
  getent passwd "$WEB_USER" >/dev/null ||
    useradd --system --no-create-home --home-dir "$WORK_DIR" --shell /usr/sbin/nologin "$WEB_USER"
  [ -z "$OPERATOR_USER" ] || getent passwd "$OPERATOR_USER" >/dev/null || refuse "OPERATOR_USER=$OPERATOR_USER is not a user on this machine"
}

ensure_dirs() {
  local web_group; web_group=$(id -gn "$WEB_USER")
  install -d -o root -g root -m 755 "$libexec" /usr/local/lib/usb16x16-dante "$plugin_dir" /etc/usb16x16 "$dante_etc" /etc/usb16x16/dsp
  install -d -o "$OWNER_USER" -g "$(id -gn "$OWNER_USER")" -m 750 /var/lib/usb16x16-dante
  install -d -o root -g root -m 755 "$WORK_DIR" "$WORK_DIR/web-ui" "$WORK_DIR/web-ui/compiler"
  install -d -o "$WEB_USER" -g "$web_group" -m 755 "$WORK_DIR/web-presets"
  # Requests from the page to root: a directory the web account can drop files
  # into and can neither list nor tidy; root's own status files live apart, in
  # a directory only root writes (docs/web/ACCESS.md).
  install -d -o root -g root -m 755 /var/spool/usb-aoip
  install -d -o root -g "$web_group" -m 1730 "$inbox"
  install -d -o root -g root -m 755 "$apply_state"
  # The page's logins: root's file, readable by the web account's group.
  [ -e "$auth_file" ] || install -o root -g "$web_group" -m 640 /dev/null "$auth_file"
  chown root:"$web_group" "$auth_file"; chmod 640 "$auth_file"
}

mgmt_address() { ip -o -4 addr show dev "$MGMT_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# TLS for the page. self-signed: a key and certificate made here, for this
# unit's names and addresses; the browser warns once and the fingerprint
# printed here is what to compare its warning with. provided: your own files.
setup_tls() {
  local web_group dir=/etc/usb-aoip/tls args= ip host san
  web_group=$(id -gn "$WEB_USER")
  case "$WEB_TLS" in
    off) ;;
    provided)
      [ -r "$WEB_TLS_CERT" ] && [ -r "$WEB_TLS_KEY" ] || refuse "WEB_TLS=provided: $WEB_TLS_CERT or $WEB_TLS_KEY cannot be read"
      runuser -u "$WEB_USER" -- test -r "$WEB_TLS_KEY" || refuse "WEB_TLS=provided: $WEB_USER cannot read $WEB_TLS_KEY (group $web_group, mode 640)"
      args="--tls-cert $WEB_TLS_CERT --tls-key $WEB_TLS_KEY" ;;
    self-signed)
      ip=${WEB_BIND:-$(mgmt_address)}
      host=$(hostname)
      install -d -o root -g "$web_group" -m 750 "$dir"
      # Made once; made again only when the address it must answer on is not in it.
      if [ ! -s "$dir/web.crt" ] || [ ! -s "$dir/web.key" ] ||
         { [ -n "$ip" ] && ! openssl x509 -in "$dir/web.crt" -noout -checkip "$ip" 2>/dev/null | grep -q 'does match'; }; then
        san="DNS:$host,DNS:$host.local,DNS:localhost,IP:127.0.0.1${ip:+,IP:$ip}"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
          -subj "/CN=$host" -addext "subjectAltName=$san" -addext "basicConstraints=critical,CA:FALSE" \
          -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=serverAuth" \
          -keyout "$dir/web.key.new" -out "$dir/web.crt.new" 2>/dev/null || refuse "openssl could not make the certificate"
        chown root:"$web_group" "$dir/web.key.new" "$dir/web.crt.new"; chmod 640 "$dir/web.key.new"; chmod 644 "$dir/web.crt.new"
        mv -f "$dir/web.key.new" "$dir/web.key"; mv -f "$dir/web.crt.new" "$dir/web.crt"
        say "made a self-signed certificate for $san"
      fi
      say "the page's certificate: $(openssl x509 -in "$dir/web.crt" -noout -fingerprint -sha256 | sed 's/.*=//')"
      say "your browser will warn about it once; that fingerprint is what its warning should show"
      args="--tls-cert $dir/web.crt --tls-key $dir/web.key" ;;
  esac
  [ -z "$WEB_BIND" ] || args="$args --bind $WEB_BIND"
  printf '# Written by install.sh from install.conf (WEB_TLS, WEB_BIND).\nUSB_AOIP_WEB_ARGS=%s\n' "${args# }" > /etc/usb-aoip/web.env
  chmod 644 /etc/usb-aoip/web.env
}

page_url() {
  local scheme=http ip; [ "$WEB_TLS" = off ] || scheme=https
  ip=${WEB_BIND:-$(mgmt_address)}
  echo "$scheme://${ip:-<address of $MGMT_IF>}:$WEB_PORT"
}

build_modules() {   # build_modules KERNELVER: the DKMS package added and built for that kernel
  local src=/usr/src/$dkms_name-$dkms_version running=$1
  say "building the gadget modules for $running with DKMS"
  dkms remove "$dkms_name/$dkms_version" --all >/dev/null 2>&1 || true
  rm -rf "$src"
  install -d -m 755 "$src" "$src/patches"
  install -m 644 "$repo"/kernel/dkms/dkms.conf "$repo"/kernel/dkms/Kbuild "$repo"/kernel/dkms/upstream.sha256 "$src/"
  install -m 755 "$repo"/kernel/dkms/prepare-sources.sh "$src/"
  install -m 644 "$repo"/kernel/uac2-shared-clock-6.18.34.patch "$repo"/kernel/uac2-discrete-channel-names-6.18.34.patch \
                 "$repo"/kernel/uac2-rate-report-6.18.34.patch "$repo"/kernel/uac2-rate-request-6.18.34.patch "$src/patches/"
  dkms add "$dkms_name/$dkms_version" >/dev/null
  dkms build "$dkms_name/$dkms_version" -k "$running" ||
    refuse "the gadget modules did not build; the reason is in /var/lib/dkms/$dkms_name/$dkms_version/build/make.log"
}

install_modules() {
  local running; running=$(uname -r)
  build_modules "$running"
  dkms install "$dkms_name/$dkms_version" -k "$running" --force >/dev/null
  depmod -a "$running"
  case "$(modinfo -F filename usb_f_uac2 2>/dev/null)" in
    */updates/*) ;;
    *) refuse "modprobe would still load the stock usb_f_uac2 ($(modinfo -F filename usb_f_uac2 2>/dev/null)); the patched one did not take" ;;
  esac
}

setup_audio_if() {
  [ "$AUDIO_IF_SETUP" = link-local ] || return 0
  command -v nmcli >/dev/null || refuse "AUDIO_IF_SETUP=link-local needs NetworkManager"
  nmcli -t -f NAME connection show | grep -qx "aoip-$AUDIO_IF" && return 0
  say "creating the NetworkManager connection aoip-$AUDIO_IF (IPv4 link-local)"
  nmcli connection add type ethernet ifname "$AUDIO_IF" con-name "aoip-$AUDIO_IF" \
    ipv4.method link-local ipv6.method link-local connection.autoconnect yes connection.autoconnect-priority 10 >/dev/null
  warn "aoip-$AUDIO_IF takes over $AUDIO_IF at the next link change or reboot; if you are logged in over that port, expect the address to change"
}

install_built() { # install_built MODE SRC DEST
  install -o root -g root -m "$1" "$2" "$3"
  rendered+=("$3 $(sha "$3")")
}

write_manifest() {
  {
    echo "# usb-aoip manifest: what install.sh put on this machine, with sha256."
    echo "# repo $(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown) kernel $(uname -r) date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "${rendered[@]}" | sort
  } > "$manifest.new"
  mv -f "$manifest.new" "$manifest"
  chmod 644 "$manifest"
}

cmd_install() {
  need_root
  load_conf
  preflight
  install -d -m 755 "$state"
  say "installing packages"
  apt-get update -q
  # shellcheck disable=SC2086
  apt-get install -y -q $packages
  ensure_kernel
  ensure_udc
  ensure_users
  ensure_dirs
  cmd_build
  local out=$build_dir/out was_active=0

  systemctl is-active --quiet usb16x16-dante.service 2>/dev/null && was_active=1
  systemctl stop usb16x16-web.service usb16x16-apply.path usb16x16-dante-rate.path usb16x16-dante.service \
                 usb16x16-statime.service usb-16x16.service 2>/dev/null || true
  install_modules
  render
  install_built 755 "$out/usb16x16-dante-owner"            "$libexec/usb16x16-dante-owner"
  install_built 755 "$out/statime"                         "$libexec/statime"
  install_built 644 "$out/libasound_module_pcm_inferno.so" "$plugin_dir/libasound_module_pcm_inferno.so"
  install_built 755 "$out/usb16x16-dsp-offline"            /usr/local/libexec/usb16x16-dsp-offline
  local f
  for f in u_audio usb_f_uac2; do
    f=$(modinfo -F filename "$f"); rendered+=("$f $(sha "$f")")
  done
  [ ! -e /etc/sudoers.d/usb16x16-dante ] || visudo -cf /etc/sudoers.d/usb16x16-dante >/dev/null ||
    { rm -f /etc/sudoers.d/usb16x16-dante; refuse "the sudoers rule did not pass visudo and was removed"; }
  write_manifest

  setup_audio_if
  setup_tls
  [ ! -e /etc/tmpfiles.d/usb-aoip-clock.conf ] || systemd-tmpfiles --create /etc/tmpfiles.d/usb-aoip-clock.conf
  sysctl -q -p /etc/sysctl.d/90-usb16x16-compaction.conf
  systemctl reload NetworkManager 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable --quiet usb-16x16.service usb16x16-governor.service usb16x16-statime.service usb16x16-dante.service \
    usb16x16-dante-startcheck.service usb16x16-dante-rate.path usb16x16-apply.path
  [ -z "$KEEPALIVE_TARGETS" ] || systemctl enable --quiet --now usb16x16-wlan-keepalive.service
  systemctl restart usb16x16-governor.service usb-16x16.service
  systemctl restart usb16x16-statime.service usb16x16-dante-rate.path usb16x16-apply.path
  systemctl restart usb16x16-dante.service || warn "usb16x16-dante did not start; see: journalctl -u usb16x16-dante -n 50"

  if grep -q '^[^#]' "$auth_file" 2>/dev/null; then
    systemctl enable --quiet usb16x16-web.service
    systemctl restart usb16x16-web.service
    say "the page: $(page_url)"
  elif [ -t 0 ] && [ -n "$OPERATOR_USER" ]; then
    say "the web page needs a login. Making one for '$OPERATOR_USER' (set-password NAME adds others):"
    cmd_set_password "$OPERATOR_USER" || say "no login made; later: sudo install/install.sh set-password NAME"
  else
    say "the web page has no login yet, so its service is not started. Add one:"
    say "    sudo install/install.sh set-password NAME"
  fi
  say "installed. The endpoint takes about a minute to settle; then:"
  say "    sudo install/install.sh status"
}

cmd_set_password() {
  need_root
  [ -n "${WEB_USER:-}" ] || load_conf
  local name=${1:-}
  [[ $name =~ ^[A-Za-z0-9._-]{1,32}$ ]] || refuse "usage: install.sh set-password NAME"
  [ -x /usr/local/bin/usb16x16-web ] || refuse "usb16x16-web is not installed yet"
  # Run as root: the login file is root's, and the web account only reads it.
  # The password is asked for twice at the terminal and never appears on a command line.
  /usr/local/bin/usb16x16-web --auth-file "$auth_file" --add-user "$name"
  chown root:"$(id -gn "$WEB_USER")" "$auth_file"; chmod 640 "$auth_file"
  systemctl enable --quiet usb16x16-web.service
  systemctl restart usb16x16-web.service
  say "the page: $(page_url)"
}

# ---------------------------------------------------------------- status ---

cmd_status() {
  local bad=0 path want now u
  [ -r "$manifest" ] || refuse "no manifest at $manifest: nothing was installed by install.sh (or adopted) here"
  load_conf
  say "config $conf_file; $(sed -n 2p "$manifest" | sed 's/^# //')"
  while read -r path want; do
    case "$path" in ''|'#'*) continue ;; esac
    if [ ! -e "$path" ]; then echo "  MISSING  $path"; bad=1; continue; fi
    now=$(sha "$path")
    case "$path" in
      # Rewritten in service by the applier or the operator: reported, not judged.
      "$dante_etc/owner.conf"|"$dante_etc/asound-inferno-owner.conf"|"$dante_etc/transport.conf"|"$dante_etc/startcheck.conf")
        [ "$now" = "$want" ] || echo "  changed  $path (${now:0:8}, installed ${want:0:8}): settings, expected to move" ;;
      *) [ "$now" = "$want" ] || { echo "  CHANGED  $path (${now:0:8}, installed ${want:0:8})"; bad=1; } ;;
    esac
  done < "$manifest"
  [ "$bad" = 0 ] && say "every installed file is as installed"
  echo "  kernel   $(uname -r) (pin $KERNEL_PIN)$([ "$(uname -r)" = "$KERNEL_PIN" ] || echo '  NOT THE PINNED KERNEL')"
  echo "  modules  usb_f_uac2 from $(modinfo -F filename usb_f_uac2 2>/dev/null || echo '?')"
  [ -e "/sys/class/udc/$USB_UDC" ] && echo "  udc      $USB_UDC present" || { echo "  udc      $USB_UDC MISSING"; bad=1; }
  for u in usb-16x16.service usb16x16-statime.service usb16x16-dante.service usb16x16-dante-rate.path usb16x16-apply.path usb16x16-web.service; do
    printf '  %-28s %s, %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)" "$(systemctl is-enabled "$u" 2>/dev/null || true)"
  done
  echo "  start check: $(cat /run/usb16x16-dante-startcheck/status 2>/dev/null || echo 'no status yet')"
  grep -q "$DEVICE_NAME" /proc/asound/cards 2>/dev/null || [ -d /proc/asound/UAC2Gadget ] || echo "  gadget sound card not present (is a host connected and the gadget started?)"
  return $bad
}

# ------------------------------------------------------------- uninstall ---

cmd_uninstall() {
  need_root
  [ -r "$manifest" ] || refuse "no manifest at $manifest: nothing to uninstall"
  grep -q '^# adopted' "$manifest" && refuse "this unit was adopted, not installed by install.sh; its own rollback chain removes it"
  load_conf
  local path _ u
  for u in usb16x16-web.service usb16x16-apply.path usb16x16-dante-rate.path usb16x16-dante-startcheck.service \
           usb16x16-dante.service usb16x16-statime.service usb16x16-wlan-keepalive.service usb16x16-governor.service usb-16x16.service; do
    systemctl disable --quiet --now "$u" 2>/dev/null || true
  done
  while read -r path _; do
    case "$path" in ''|'#'*) continue ;; /lib/modules/*) continue ;; esac
    if [ "$purge" = 0 ]; then
      case "$path" in "$dante_etc"/*.conf|"$dante_etc"/statime.toml) continue ;; esac
    fi
    rm -f "$path"
  done < "$manifest"
  dkms remove "$dkms_name/$dkms_version" --all >/dev/null 2>&1 || true
  rm -rf "/usr/src/$dkms_name-$dkms_version"
  depmod -a
  rmdir "$units"/usb16x16-*.service.d "$libexec" "$plugin_dir" /usr/local/lib/usb16x16-dante 2>/dev/null || true
  rm -f /etc/sysctl.d/90-usb16x16-compaction.conf; sysctl -q vm.compact_unevictable_allowed=1 2>/dev/null || true
  apt-mark unhold "linux-image-$KERNEL_PIN" "linux-headers-$KERNEL_PIN" >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl reload NetworkManager 2>/dev/null || true
  if [ "$purge" = 1 ]; then
    rm -rf /etc/usb16x16 /var/lib/usb16x16-dante "$WORK_DIR" "$state" /etc/usb-aoip /var/cache/usb-aoip-uac2 /var/spool/usb-aoip "$apply_state"
    userdel "$WEB_USER" 2>/dev/null || true; userdel "$OWNER_USER" 2>/dev/null || true
    say "removed, with its settings, presets, Dante identity and config"
  else
    rm -f "$manifest"
    say "removed. Kept: /etc/usb-aoip, /etc/usb16x16 (settings), /var/lib/usb16x16-dante (Dante identity"
    say "and subscriptions), $WORK_DIR (presets), the logins and certificate in /etc/usb-aoip. --purge removes those too."
  fi
  say "left alone: the packages, the held kernel (now unheld), /boot/firmware/config.txt, and any aoip-$AUDIO_IF connection"
}

# ----------------------------------------------------------------- adopt ---
# For the unit the old chain built. Reads what is installed, writes the
# config that describes it and a manifest of its hashes. It writes two
# files, /etc/usb-aoip/install.conf and the manifest, and nothing else.

cmd_adopt() {
  need_root
  [ ! -e "$conf_file" ] || refuse "$conf_file exists already"
  local inferno=$dante_etc/asound-inferno-owner.conf gadget=/usr/local/sbin/setup-usb-aoip web=$units/usb16x16-web.service
  local f v
  for f in "$inferno" "$gadget" "$web" "$dante_etc/statime.toml"; do [ -r "$f" ] || refuse "$f is not there: this is not a unit the chain built"; done
  val() { sed -n "$1" "$2" | head -1; }
  install -d -m 755 "$(dirname "$conf_file")" "$state"
  {
    echo "# Written by 'install.sh adopt' on $(date -u +%Y-%m-%d) from what is installed on this unit."
    echo "OPERATOR_USER=$(val 's/^\([a-z_][a-z0-9_-]*\) ALL=.*/\1/p' /etc/sudoers.d/usb16x16-dante 2>/dev/null)"
    echo "WEB_USER=$(val 's/^User=//p' "$web")"
    echo "OWNER_USER=$(val 's/^User=//p' "$units/usb16x16-dante.service")"
    echo "WORK_DIR=$(val 's|.*--static \(/[^ ]*\)/web-ui.*|\1|p' "$web")"
    echo "AUDIO_IF=$(val 's/^interface = "\(.*\)"/\1/p' "$dante_etc/statime.toml")"
    echo "AUDIO_IF_SETUP=none"
    echo "MGMT_IF=$(val 's/.*--management-interface \([^ ]*\).*/\1/p' "$web")"
    echo "WEB_PORT=$(val 's/.*--port \([0-9]*\).*/\1/p' "$web")"
    echo "KEEPALIVE_TARGETS=$(grep -o -- '-I [^ ]* [0-9a-fA-F:.]*' "$units/usb16x16-wlan-keepalive.service" 2>/dev/null | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//')"
    echo "DEVICE_NAME=$(val 's/^[[:space:]]*NAME "\(.*\)"/\1/p' "$inferno")"
    echo "USB_MANUFACTURER=$(val "s|.*'\\(.*\\)' > \"\\\$G/strings/0x409/manufacturer\"|\\1|p" "$gadget")"
    echo "USB_SERIAL=$(val 's|.* \([A-Za-z0-9]*\) > "\$G/strings/0x409/serialnumber"|\1|p' "$gadget")"
    echo "USB_VID=$(val 's|.* \(0x[0-9a-fA-F]*\) > "\$G/idVendor"|\1|p' "$gadget")"
    echo "USB_PID=$(val 's|.* \(0x[0-9a-fA-F]*\) > "\$G/idProduct"|\1|p' "$gadget")"
    echo "USB_UDC=$(val 's/^UDC=//p' "$gadget")"
    echo "USB_RATES=$(val 's/^RATES=//p' "$gadget")"
    echo "DANTE_RATES=$(val 's/^[[:space:]]*SUPPORTED_SAMPLE_RATES "\(.*\)"/\1/p' "$inferno")"
    echo "DANTE_DEVICE_ID=$(val 's/^[[:space:]]*DEVICE_ID "\(.*\)"/\1/p' "$inferno")"
    echo "DANTE_STATE_ID=$(val 's/^[[:space:]]*STATE_ID "\(.*\)"/\1/p' "$inferno")"
    echo "KERNEL_PIN=$(uname -r)"
  } > "$conf_file.new"
  ( load_conf "$conf_file.new" ) || { say "what was read is in $conf_file.new; nothing else was written"; exit 2; }
  mv "$conf_file.new" "$conf_file"
  {
    echo "# adopted: hashes of the unit as the old chain left it; install.sh did not put these here."
    echo "# kernel $(uname -r) date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in "$units"/usb-16x16.service "$units"/usb-16x16.service.d/*.conf "$units"/usb16x16-*.service "$units"/usb16x16-*.path \
             "$units"/usb16x16-*.service.d/*.conf "$libexec"/usb16x16-dante-owner "$libexec"/usb16x16-dante-start \
             "$libexec"/usb16x16-dante-startcheck "$libexec"/statime "$plugin_dir"/*.so "$dante_etc"/* \
             /usr/local/sbin/setup-usb-aoip /usr/local/sbin/usb16x16-stall-tuning /usr/local/bin/usb16x16-web \
             /usr/local/bin/usb16x16-apply /usr/local/libexec/usb16x16-dsp-offline /etc/sysctl.d/90-usb16x16-compaction.conf \
             /etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf /etc/sudoers.d/usb16x16-* \
             "$(modinfo -F filename u_audio 2>/dev/null)" "$(modinfo -F filename usb_f_uac2 2>/dev/null)"; do
      [ -f "$f" ] && echo "$f $(sha "$f")"
    done | sort
  } > "$manifest"
  say "wrote $conf_file and $manifest; nothing else was touched."
  grep -v '^#' "$conf_file" | sed 's/^/    /'
  say "'install.sh status' now reports this unit. 'install.sh install' is refused on it while the AES67 service is enabled;"
  say "compare a render of this config with what is installed before ever moving it to the new installer (docs/INSTALL.md)."
}

# ------------------------------------------------------------------ main ---

command=${1:-}; [ $# -gt 0 ] && shift
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      root=${2:?--root DIR}; shift 2 ;;
    --config)    conf_file=${2:?--config FILE}; shift 2 ;;
    --build-dir) build_dir=${2:?--build-dir DIR}; shift 2 ;;
    --with-dev-tools) with_dev_tools=1; shift ;;
    --with-port-state) with_port_state=1; shift ;;
    --purge)     purge=1; shift ;;
    *)           args+=("$1"); shift ;;
  esac
done
case "$command" in
  config)       cmd_config ;;
  install)      cmd_install ;;
  status)       cmd_status ;;
  uninstall)    cmd_uninstall ;;
  adopt)        cmd_adopt ;;
  render)       cmd_render ;;
  build)        cmd_build ;;
  build-modules) need_root; build_modules "${args[0]:-$(uname -r)}"
                 find "/var/lib/dkms/$dkms_name/$dkms_version" -name '*.ko*' -exec sh -c 'echo "    $(sha256sum "$1" | cut -c1-64)  $(basename "$1")"' _ {} \; ;;
  set-password) cmd_set_password "${args[0]:-}" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
