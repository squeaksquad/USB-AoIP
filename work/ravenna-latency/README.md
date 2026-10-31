# Reversible RAVENNA platform-latency sweep

This wrapper runs the upstream `run_latency_test.sh` against the exact validated
Pi artifacts without modifying the source checkout:

- daemon: `/home/bdimaio/usb-16x16-work/aes67-daemon-src/build-daemon/aes67-daemon`
- driver: `ravenna-alsa-lkm-v2.1/driver/MergingRavennaALSA.ko`
- expected driver SHA-256:
  `f65a49558a0f8f16efbbe7afa45464d41529faacfcb1a838e897f99d9649604e`

Safety behavior:

- requires interactive `sudo` and refuses to run as an ordinary user;
- refuses any existing `ptp4l`, `aes67-daemon`, `alsaloop`, or loaded RAVENNA
  module instead of terminating unrelated work;
- runs the upstream test from a temporary directory;
- compiles the upstream latency utility against a project-private
  `libasound2-dev` extraction, without changing Pi OS package state;
- permits `ptp4l` only on the loopback interface used by the platform test;
- records and restores all sysctls changed by the upstream script;
- stops test processes, unloads the module, and removes its temporary directory;
- verifies the protected USB service and `configured/high-speed` after each point;
- preserves one log per frame-size/sink-delay point under the Pi work directory.

The default reconnaissance sweep is 384, 192, 144, and 96 frames, 16 channels,
48 kHz, packed 24-bit, and ten seconds per point. Run on the Mac:

```bash
ssh -o HostKeyAlias=audio-dev.local bdimaio@169.254.92.97 \
  'sudo -n /usr/local/sbin/run-ravenna-latency-safe.sh'
```

The run is fully unattended. The 30-second PTP lock wait in
the upstream test means the four-point sweep takes several minutes. Short runs
are reconnaissance, not the required ten-minute acceptance soak.

To hold the RAVENNA period at 96 frames and sweep only the configured sink
delay:

```bash
ssh -o HostKeyAlias=audio-dev.local bdimaio@169.254.92.97 \
  'USB16X16_RAVENNA_SINK_DELAYS="576 288 144 96 48" \
    sudo -n /usr/local/sbin/run-ravenna-latency-safe.sh 96'
```
