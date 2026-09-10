# `metadata.txt` in this directory records arguments that were never used

This was the first run of `run-dsp-candidate-safe.sh`, and that wrapper
inherited its metadata block from `run-phase4-candidate-safe.sh`, which echoes
the twenty positional variables. This wrapper does not use them: it hardcodes
the accepted profile's argument list. So the file records the *defaults of
variables the launch ignored*.

Where it disagrees with what actually ran:

| `metadata.txt` says | The bridge was given |
| --- | --- |
| `period_frames=96` | `--period 48` |
| `buffer_frames=384` | `--buffer 192` |
| `target_frames=192` | `--target 48` |
| `playback_prime_frames=0` | `--playback-prime 96` |
| `tx_playback_prime_frames=0` | `--tx-playback-prime 192` |
| `rx_playback_prime_frames=0` | `--rx-playback-prime 120` |
| `usb_pitch_servo=0` | `--usb-pitch-servo 1` |
| `align_start=0` | `--align-start 1` |
| `align_tx_trigger=0` | `--align-tx-trigger 1` |
| `align_tx_prime=0` | `--align-tx-prime 1` |
| `zero_run_detect=0` | `--zero-run-detect 1` |

`sink_delay=103`, `candidate_seconds=360` and `bridge_sha256` are correct.

**`bridge.log` is authoritative.** It carries the real argument list on its
first lines, and the run's behaviour confirms it: the ALIGN and PRIMED lines
only exist because the aligned start and prime ran, and `ppm=-13.697` is the
pitch servo, which `usb_pitch_servo=0` would have left off.

The wrapper now builds one argument array and records that, so the launch and
the record cannot disagree again.
