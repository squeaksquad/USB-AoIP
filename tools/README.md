# tools/

Measurement and diagnosis. None of it is installed on the device.

| Path | What it is |
|---|---|
| `latency-harness/` | Swift CoreAudio tool (macOS): round-trip latency, bit transparency, soaks. |
| `diag/` | Watchers for the Pi (transmit queue, owner scheduling, page migration) and the reader for a capture of the Dante flows. |
| `analysis/` | Readers for harness output and captures: zero runs, gaps, per-channel zeros, one Dante rate set. |
| `channel-id/` | Generates and analyses the channel-identity test file. |
| `inspect-pi.sh` | Read-only inventory of a Pi. |

`dante/measure-candidate.sh` drives the harness against a running endpoint.
