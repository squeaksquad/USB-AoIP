# dante/

The network side: an unofficial Dante-compatible endpoint built on
[Inferno](https://gitlab.com/lumifaza/inferno), with Statime as the PTP
follower. Not an Audinate product.

| Path | What it is |
|---|---|
| `owner/` | `usb16x16-dante-owner`, the one long-lived process that moves audio between the USB gadget and the Inferno ALSA plugin. `main.cpp` has the build line in its header; it links `../dsp-core/src/bridge_core.cpp`. The `*_test.cpp` files test the headers and build anywhere. |
| `patches/` | The five patches applied to Inferno, in order. |
| `SOURCES.lock` | The pinned Inferno and Statime revisions and the hashes of what was built from them. |
| `build-candidate.sh`, `build-patched.sh` | Build Statime and the patched plugin on the Pi. |
| `config/` | The installed Inferno ALSA config, Statime's first-run config, and the DSP test presets. |
| `service/` | Units, the start wrapper, the start check, the rate arbiter units, `transport-*.conf`, the sysctl and NetworkManager drop-ins, and the wrapper's tests. |
| `measure-candidate.sh`, `soak_reference.py` | Mac-side measurement of the running endpoint with `tools/latency-harness`. |

What is installed, from `service/` and `config/` (the point of record of
2026-11-01):

- `usb16x16-dante-start-transport` is installed as the start wrapper;
  `usb16x16-dante-start` is its predecessor, kept because the tests compare
  the two.
- `transport-rate882.conf` is the installed `transport.conf`. The other
  `transport-*.conf` files are its earlier forms; `test-dante-start.sh
  transport` checks that each step left the owner's command line unchanged
  where it should.
- `config/asound-inferno-owner-usb-aoip-rate882.conf` is the installed
  Inferno config.

Design documents are in `docs/design/dante/`; superseded installers and
configs in `history/installers/dante/`.
