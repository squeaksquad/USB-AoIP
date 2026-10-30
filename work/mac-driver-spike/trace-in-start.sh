#!/bin/bash
# trace-in-start.sh on [SECONDS] | off: kprobe trace of the gadget's isochronous start, for the
# host-driver spike (SPIKE_PLAN.md, "Phase B, step 1"): how many IN packets the host gets before
# the first frame from the owner's queue, and why that number drifts between opens.
#
# One probe fires per USB completion of the audio endpoints (u_audio_iso_complete: about 16,000 a
# second while a host streams both ways), the rest per event (alt setting, stream start and stop,
# PCM trigger, endpoint enable). The per-packet probe is why the trace is bounded: `on` switches
# itself off after SECONDS (default 45, at most 120), about 1.8 MB a second into
# /dev/shm/in-start/trace.log on a Pi with 1 GB. Run it with sudo, then start the host's opens.
#
# struct usb_request offsets (6.18.34+rpt, include/linux/usb/gadget.h, arm64): length +16,
# frame_number +88, status +92, actual +96. The completion's arguments: %x0 the endpoint, %x1 the
# request.
set -u
self=$(readlink -f "$0")
T=/sys/kernel/tracing; DIR=/dev/shm/in-start; OUT=$DIR/trace.log; PIDF=/run/in-start-trace.pid
probes=(
 "p:instart/iso u_audio:u_audio_iso_complete ep=%x0:x64 len=+16(%x1):u32 frame=+88(%x1):u32 status=+92(%x1):s32 actual=+96(%x1):u32"
 "p:instart/set_alt usb_f_uac2:afunc_set_alt intf=%x1:u32 alt=%x2:u32"
 "p:instart/start_p u_audio:u_audio_start_playback"
 "p:instart/stop_p u_audio:u_audio_stop_playback"
 "p:instart/start_c u_audio:u_audio_start_capture"
 "p:instart/stop_c u_audio:u_audio_stop_capture"
 "p:instart/trigger u_audio:uac_pcm_trigger ss=%x0:x64 cmd=%x1:s32"
 "p:instart/ep_enable usb_ep_enable ep=%x0:x64"
 "p:instart/ep_disable usb_ep_disable ep=%x0:x64"
)

off() {
  echo 0 > $T/tracing_on; echo 0 > $T/events/instart/enable 2>/dev/null
  [ -f $PIDF ] && kill "$(cat $PIDF)" 2>/dev/null; rm -f $PIDF
  for p in "${probes[@]}"; do n=${p#*:}; n=${n%% *}; echo "-:$n" >> $T/kprobe_events 2>/dev/null; done
  echo 1408 > $T/buffer_size_kb
  echo "tracing off; $(wc -l < $OUT 2>/dev/null || echo 0) lines in $OUT; remaining kprobes: $(wc -l < $T/kprobe_events)"
}

case "${1:-}" in
on)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  seconds=${2:-45}
  case "$seconds" in ''|*[!0-9]*) echo "SECONDS must be a whole number"; exit 2;; esac
  [ "$seconds" -ge 1 ] && [ "$seconds" -le 120 ] || { echo "SECONDS must be 1 to 120"; exit 2; }
  [ -f $PIDF ] && { echo "already tracing (reader $(cat $PIDF)); run: $self off"; exit 1; }
  mkdir -p $DIR
  echo 0 > $T/tracing_on; echo > $T/trace; echo 8192 > $T/buffer_size_kb
  for p in "${probes[@]}"; do
    if echo "$p" >> $T/kprobe_events 2>/dev/null; then echo "ok   ${p%% *} ${p#* }" | cut -c1-90; else echo "FAIL $p"; fi
  done
  echo 1 > $T/events/instart/enable
  : > $OUT; chmod 644 $OUT
  nohup cat $T/trace_pipe >> $OUT 2>/dev/null & echo $! > $PIDF
  echo 1 > $T/tracing_on
  # The bound: off by itself after $seconds, whatever happens to this shell.
  nohup bash -c "sleep $seconds; '$self' off >> $DIR/off.log 2>&1" > /dev/null 2>&1 &
  echo "tracing for $seconds s (reader $(cat $PIDF)), log $OUT; start the host's opens now";;
off)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  off;;
*) echo "usage: $0 on [SECONDS] | off"; exit 2;;
esac
