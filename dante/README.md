# dante/

The network side: an unofficial Dante-compatible endpoint built on
[Inferno](https://gitlab.com/lumifaza/inferno), with Statime as the PTP
follower. Not an Audinate product.

| Path | What it is |
|---|---|
| `owner/` | `usb16x16-dante-owner`, the one long-lived process that moves audio between the USB gadget and the Inferno ALSA plugin. `main.cpp` has the build line in its header; it links `../dsp-core/src/bridge_core.cpp`. The `*_test.cpp` files test the headers and build anywhere. `monitor_ctl.hpp` is the monitor block's control (the three files of `docs/web/MONITOR-FILES.md`; options `--monitor-state`, `--monitor-saved`, `--monitor-limits`, `--monitor-status` with compiled-in defaults, `--no-monitor`); `monitor_sim.cpp` runs it and the stage without ALSA for end-to-end checks on the Mac, and is not installed. |
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

## Updating the development unit's owner (the monitor block)

The phase 3 owner (`owner/main.cpp` with the monitor block) and the offline
runner that knows the artifact's monitor section go onto the author's Pi
with three scripts in `install/dev-unit/`, written 2026-11-18, not yet run:

- `stage-owner-monitor.sh [OUT_DIR]` (Mac) makes the bundle: the owner's
  source and every header it includes, `dsp-core`'s header, core, runner
  and CMake file, the build script, and `owner-monitor.sha256`, which must
  equal the repository's copy (a changed source fails staging until it is
  re-pinned on purpose).
- `build-owner-monitor.sh` (on the Pi, unprivileged, refuses root) builds
  both with `install/install.sh`'s lines into `out/`, checks `--help`
  shows the monitor options, that both binaries carry the monitor loader,
  and that the runner loads a monitor artifact, and writes the two hashes
  to `out/BUILD.txt`. It installs nothing.
- `install-owner-monitor.sh install|rollback|status` (on the Pi, sudo)
  replaces owner c84e6a36 and runner 4492a19c, requiring start wrapper
  df6a1b0b, keeping `*.pre-monitor`. Its `OWNER_NEW` and `RUNNER_NEW` are
  empty until the hashes `build-owner-monitor.sh` printed are reported and
  pinned; until then `install` refuses. `rollback` refuses while the
  running preset, or its artifact at another rate, has a monitor section.

Order: this first (the old page never emits a monitor section), then
`install-access.sh install` for the page bundle; rollback in the reverse
order. It is an owner change: the full battery. `test-owner-monitor.sh`
checks all of it against a stand-in root (CI, `install-render`).

## The owner's idle phase (not installed)

`owner/idle-phase.patch` (2026-11-20) adds `--idle-phase US` to the owner.
It is not applied in the tree: `owner/main.cpp` stays the installed owner's
source, and the candidate is built with the patch applied to a copy. Its
service form, written 2026-11-20 and not installed:

- `service/usb16x16-dante-start-transport` has the transport key
  `IDLE_PHASE` (0 to 999, per rate like the others); without it the command
  line is the one before. The from-scratch installer installs this wrapper
  with `transport-rate882.conf`, so it passes nothing new.
- `service/transport-idlephase.conf` is `transport-rate882.conf` with
  `IDLE_PHASE=60`.
- `install/dev-unit/stage-owner-idlephase.sh`, `build-owner-idlephase.sh`
  and `install-owner-idlephase.sh install|rollback|status` put the patched
  owner bb3cd6ca, that wrapper and that `transport.conf` on the author's Pi
  in place of bc486911, df6a1b0b and add1bc21, keeping
  `*.idlephase-previous`. It goes on after `install-owner-monitor.sh`; its
  rollback comes before that one's. It is an owner change: the full battery
  at 48 and 96 kHz. `test-owner-idlephase.sh` checks it against a stand-in
  root (CI, `install-render`).

Design documents are in `docs/design/dante/`; superseded installers and
configs in `history/installers/dante/`.
