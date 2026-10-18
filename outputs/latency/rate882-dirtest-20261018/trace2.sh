#!/bin/bash
# trace2.sh on|off: trace.sh probes plus a per-packet probe on the gadget IN endpoint,
# enabled only in short windows. A window is asked for by creating
# /dev/shm/rate882/window (contents: seconds, 1-5, and a label); a root poller opens
# it, marks start and end in the trace, then deletes the request. Output: trace.log.
set -u
T=/sys/kernel/tracing; OUT=/dev/shm/rate882/trace2.log; REQ=/dev/shm/rate882/window
PIDF=/run/rate882-trace2.pids
# struct usb_request (6.18, arm64): buf +8, length +16, frame_number +88, status +92, actual +96.
# Content: 8 bytes from frame 0 at channel 2 (+3) and from frame 5 (+243).
iso="p:uaciso/iso u_audio:u_audio_iso_complete ep=%x0:x64 len=+16(%x1):u32 act=+96(%x1):u32 st=+92(%x1):s32 fn=+88(%x1):u32 d0=+3(+8(%x1)):x64 d5=+243(+8(%x1)):x64"
events=(
 "p:uac/set_alt usb_f_uac2:afunc_set_alt intf=%x1:u32 alt=%x2:u32"
 "p:uac/sam_freq usb_f_uac2:uac2_cs_control_sam_freq"
 "p:uac/p_srate u_audio:u_audio_set_playback_srate srate=%x1:s32"
 "p:uac/start_p u_audio:u_audio_start_playback"
 "p:uac/stop_p u_audio:u_audio_stop_playback"
 "p:uac/pcm_open u_audio:uac_pcm_open"
 "p:uac/trigger u_audio:uac_pcm_trigger cmd=%x1:s32"
 "p:uac/ep_enable usb_ep_enable ep=%x0:x64"
 "p:uac/ep_disable usb_ep_disable ep=%x0:x64"
)
case "${1:-}" in
on)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  mkdir -p /dev/shm/rate882; chmod 1777 /dev/shm/rate882
  echo 0 > $T/tracing_on; echo > $T/trace; echo 8192 > $T/buffer_size_kb
  for p in "${events[@]}" "$iso"; do echo "$p" >> $T/kprobe_events 2>/dev/null && echo "ok   ${p%% *} ${p#* }" | cut -c1-90 || echo "FAIL $p"; done
  echo 1 > $T/events/uac/enable; echo 0 > $T/events/uaciso/enable; echo 1 > $T/tracing_on
  : > $OUT; chmod 644 $OUT
  nohup cat $T/trace_pipe >> $OUT 2>/dev/null & r=$!
  nohup bash -c "
    while true; do
      if [ -f $REQ ]; then
        read s label < $REQ; s=\${s:-2}; [ \"\$s\" -ge 1 -a \"\$s\" -le 5 ] 2>/dev/null || s=2
        echo \"WINDOW start \$label \$s s\" > $T/trace_marker
        echo 1 > $T/events/uaciso/enable; sleep \$s; echo 0 > $T/events/uaciso/enable
        echo \"WINDOW end \$label\" > $T/trace_marker; rm -f $REQ
      fi
      sleep 0.2
    done" >/dev/null 2>&1 & p=$!
  echo "$r $p" > $PIDF
  echo "tracing on (reader $r, window poller $p), log $OUT";;
off)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  [ -f $PIDF ] && kill $(cat $PIDF) 2>/dev/null; rm -f $PIDF $REQ
  echo 0 > $T/tracing_on; echo 0 > $T/events/uaciso/enable 2>/dev/null; echo 0 > $T/events/uac/enable 2>/dev/null
  for p in "${events[@]}" "$iso"; do n=${p#*:}; n=${n%% *}; echo "-:$n" >> $T/kprobe_events 2>/dev/null; done
  echo 1408 > $T/buffer_size_kb
  echo "tracing off; remaining kprobes: $(wc -l < $T/kprobe_events)";;
*) echo "usage: trace2.sh on|off"; exit 2;;
esac
