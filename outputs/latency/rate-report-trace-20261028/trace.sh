#!/bin/bash
# trace.sh on|off: kprobe trace of the UAC2 gadget for the rate-report plan
# (work/uac2-discrete-channels/RATE_REPORT_PLAN.md, step 1, 2026-10-28): does an idle
# Mac's rate set reach the gadget as SET_CUR? 2026-10-18's trace.sh plus disable,
# suspend and the rate control's reads. Per event, never per packet.
# Output: /dev/shm/rate-report/trace.log.
set -u
T=/sys/kernel/tracing; OUT=/dev/shm/rate-report/trace.log; PIDF=/run/rate-report-trace.pid
probes=(
 "p:uac/set_alt usb_f_uac2:afunc_set_alt intf=%x1:u32 alt=%x2:u32"
 "r:uac/set_alt_ret usb_f_uac2:afunc_set_alt ret=\$retval:s32"
 "p:uac/sam_freq usb_f_uac2:uac2_cs_control_sam_freq"
 "p:uac/p_srate u_audio:u_audio_set_playback_srate srate=%x1:s32"
 "p:uac/c_srate u_audio:u_audio_set_capture_srate srate=%x1:s32"
 "p:uac/start_p u_audio:u_audio_start_playback"
 "p:uac/stop_p u_audio:u_audio_stop_playback"
 "p:uac/start_c u_audio:u_audio_start_capture"
 "p:uac/stop_c u_audio:u_audio_stop_capture"
 "p:uac/pcm_open u_audio:uac_pcm_open"
 "p:uac/trigger u_audio:uac_pcm_trigger cmd=%x1:s32"
 "p:uac/disable usb_f_uac2:afunc_disable"
 "p:uac/suspend usb_f_uac2:afunc_suspend"
 "p:uac/u_suspend u_audio:u_audio_suspend"
 "p:uac/rate_get u_audio:u_audio_rate_get"
)
case "${1:-}" in
on)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  mkdir -p /dev/shm/rate-report
  echo 0 > $T/tracing_on; echo > $T/trace; echo 4096 > $T/buffer_size_kb
  for p in "${probes[@]}"; do echo "$p" >> $T/kprobe_events 2>/dev/null && echo "ok   $p" || echo "FAIL $p"; done
  echo 1 > $T/events/uac/enable; echo 1 > $T/tracing_on
  : > $OUT; chmod 644 $OUT
  nohup cat $T/trace_pipe >> $OUT 2>/dev/null & echo $! > $PIDF
  echo "tracing on, reader $(cat $PIDF), log $OUT";;
off)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  echo 0 > $T/tracing_on; echo 0 > $T/events/uac/enable 2>/dev/null
  [ -f $PIDF ] && kill "$(cat $PIDF)" 2>/dev/null; rm -f $PIDF
  for p in "${probes[@]}"; do n=${p#*:}; n=${n%% *}; echo "-:$n" >> $T/kprobe_events 2>/dev/null; done
  echo 1408 > $T/buffer_size_kb
  echo "tracing off; remaining kprobes: $(wc -l < $T/kprobe_events)";;
*) echo "usage: trace.sh on|off"; exit 2;;
esac
