#!/bin/bash
# Test of usb16x16-wlan-guard with stand-in commands: no network, no root.
#   bash gadget/test-wlan-guard.sh
# The stand-ins read their answers from files in $T/state and append every
# call that changes something to $T/calls.
set -u
here=$(cd "$(dirname "$0")" && pwd)
guard=$here/usb16x16-wlan-guard
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/sys"

cat > "$T/bin/wpa_cli" <<'EOF'
#!/bin/bash
s=$STATE
shift 2                      # -i IF
case "$*" in
  "get disable_btm") [ -f $s/no-supplicant ] && exit 1; cat $s/btm ;;
  "set disable_btm 1") echo 1 > $s/btm; echo "set-btm" >> $s/calls; echo OK ;;
  status) echo "wpa_state=$(cat $s/wpa_state)" ;;
  reassociate) echo reassociate >> $s/calls; echo OK ;;
esac
EOF
cat > "$T/bin/nmcli" <<'EOF'
#!/bin/bash
s=$STATE
case "$*" in
  "radio wifi") cat $s/radio ;;
  *"device show"*) echo "GENERAL.STATE:$(cat $s/nm)" ;;
  *"device connect"*) echo connect >> $s/calls
     if [ -f $s/connect-works ]; then echo "100 (connected)" > $s/nm; echo up > $s/ping; exit 0; fi
     exit 4 ;;
esac
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/bash
[ -f $STATE/no-route ] || echo "default via 192.0.2.1 proto dhcp src 192.0.2.9 metric 600"
EOF
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
[ "$(cat $STATE/ping)" = up ]
EOF
cat > "$T/bin/modprobe" <<'EOF'
#!/bin/bash
echo "modprobe $*" >> $STATE/calls
[ "$1" = -r ] || { rm -f $STATE/no-supplicant; echo 0 > $STATE/btm; }
EOF
chmod +x "$T/bin"/*

fail=0
reset() {
  rm -f "$T/state"/*
  echo 1 > "$T/state/btm"; echo COMPLETED > "$T/state/wpa_state"
  echo enabled > "$T/state/radio"; echo "100 (connected)" > "$T/state/nm"
  echo up > "$T/state/ping"; : > "$T/state/calls"
}
run() {
  STATE=$T/state USB16X16_WLAN_GUARD_STUBS=$T/bin USB16X16_WLAN_GUARD_SYS=$T/sys \
    USB16X16_WLAN_GUARD_INTERVAL=0 bash "$guard" --ticks "$1" > "$T/out" 2>&1
}
calls() { tr '\n' ',' < "$T/state/calls"; }
check() {  # NAME EXPECTED-CALLS
  if [ "$(calls)" = "$2" ]; then echo "ok   $1"
  else echo "FAIL $1: calls '$(calls)', expected '$2'"; sed 's/^/     /' "$T/out"; fail=1; fi
}

reset; run 5
check "healthy link, capability already off: nothing done" ""

reset; echo 0 > "$T/state/btm"; run 3
check "capability on, associated: set once and re-associated once" "set-btm,reassociate,"

reset; echo 0 > "$T/state/btm"; echo DISCONNECTED > "$T/state/wpa_state"; run 1
check "capability on, not associated: set, no re-association" "set-btm,"

reset; echo down > "$T/state/ping"; run 2
check "two bad passes: not yet" ""

reset; echo down > "$T/state/ping"; touch "$T/state/connect-works"; run 6
check "dead traffic on a standing association: one reconnect, then quiet" "connect,"

reset; echo "30 (disconnected)" > "$T/state/nm"; touch "$T/state/connect-works"; run 4
check "disconnected: reconnect on the third pass" "connect,"

reset; touch "$T/state/no-route"; touch "$T/state/connect-works"; run 3
check "no default route on the interface counts as down" "connect,"

reset; echo "30 (disconnected)" > "$T/state/nm"; run 5
check "reconnect keeps failing: two attempts, a driver reload, a third" \
  "connect,connect,modprobe -r brcmfmac_cyw brcmfmac,modprobe brcmfmac,modprobe brcmfmac_cyw,set-btm,connect,"

reset; echo "30 (disconnected)" > "$T/state/nm"; run 9
check "one reload per gap, however long it fails" \
  "connect,connect,modprobe -r brcmfmac_cyw brcmfmac,modprobe brcmfmac,modprobe brcmfmac_cyw,set-btm,connect,connect,connect,connect,connect,"

reset; echo disabled > "$T/state/radio"; echo "30 (disconnected)" > "$T/state/nm"; echo 0 > "$T/state/btm"; run 6
check "Wi-Fi switched off: left alone" ""

reset; touch "$T/state/no-supplicant"; run 2
check "supplicant not answering: no error, no action while the link is good" ""

mkdir -p "$T/sys/module/xdrv/holders/xhold" "$T/sys/class/net/wlan0/device/driver"
ln -s "$T/sys/module/xdrv" "$T/sys/class/net/wlan0/device/driver/module"
reset; echo "30 (disconnected)" > "$T/state/nm"; run 5
check "driver and holder names come from sysfs" \
  "connect,connect,modprobe -r xhold xdrv,modprobe xdrv,modprobe xhold,set-btm,connect,"

[ $fail = 0 ] && echo "all passed" || echo "FAILED"
exit $fail
