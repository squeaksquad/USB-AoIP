# DSP service preflights — 2026-09-11 UTC

All three 60-second service preflights passed. The existing DSP bridge was installed; no filter arithmetic, clock, transport buffer or USB identity changed. The full acceptance battery and latency measurements remain pending.

| Arm | TX/RX floor | DSP mean/max per call | Sink lead minima | Recoveries |
| --- | --- | --- | --- | --- |
| direct | 89/72 | 0.000/0.000 µs | 1000/1004 µs | 0 |
| transparent | 86/72 | 43.408/116.554 µs | 1016/1029 µs | 0 |
| loaded | 88/72 | 58.588/200.445 µs | 1034/1042 µs | 0 |

Each run held CoreAudio open once and drove all 16 outputs with deterministic noise at amplitude 0.1. Input/output discontinuities, invalid buffers, full-scale/nonfinite samples on the required return inputs, and bridge recovery/drop/clipping/low-queue events were all zero. The longest zero run on required inputs 1/2 was one sample. All 16 return inputs additionally showed clean activity when inspected after the runs; this is supplementary coverage, not a routing test.

All three starts reported ALIGN status=ok, TX front_age_frames=296, under_prime=0, and trigger target=prime. Both DSP presets engaged after the prime. Full-preset cost was measured with 308 biquads, 26 internal channels and zero intentional delay. Mean and maximum are per-call timings; no fixed-block deadline ratio is inferred.

The loaded preset ran without the earlier recoveries when tested using continuous audio and one device open. This supports the earlier probe-retry explanation but does not by itself establish causality or long-run stability. No impulse latency or RTL measurement was performed.

Operational notes:

- Initial installation refused before file changes because the full-command-line process guard matched a path in the enclosing SSH command. Retrying installation as an isolated command succeeded. Do not include post-install sha256sum paths in the same SSH command as deployment.
- The initial direct preflight was invalid: sandboxed CoreAudio enumerated no devices and opened no audio. Outside-sandbox inspection confirmed native USB 16x16 at 48 kHz, 16 inputs/outputs and numeric channel labels. All three valid preflights used the signed harness outside the sandbox.
- New bridge 406699bd and supervisor cdc0768d remain installed. Both DSP presets remain pinned under /etc/usb16x16/dsp. The selected profile was returned to dsp-direct; final-state.json verifies active/running service, matching hashes, no DSP loaded and zero recoveries.
- The baseline bundle remains unchanged and supplies full rollback. The systemd unit, sudoers, daemon, RAVENNA module and USB gadget were not changed.
- Next: a new preflight on the selected process, then the bounded acceptance battery. UI Apply, live meters and AoIP-only DSP remain unimplemented. Do not interpret these captures as latency neutrality.

Evidence: `preflight-results-20260911.json` and each arm directory contain raw snapshots, channel statistics and machine-readable summaries.
