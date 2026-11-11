# Licensing

The project's own code and documentation are licensed under the
[Apache License 2.0](LICENSE) unless listed below. The exceptions are patches
to, and binaries built from, GPL-licensed upstream projects; they carry the
upstream licence, whose text is in [`LICENSES/`](LICENSES/).

| Files | Licence | Why |
|---|---|---|
| `kernel/*.patch` | GPL-2.0-only | Patches to the Linux kernel (`u_audio`, `f_uac2`). |
| `work/protected-baseline-2026-08-31/usb_f_uac2.ko` | GPL-2.0-only | A Linux kernel module binary; its source is the Linux 6.18.34 tree with the patches above. |
| `history/aes67/ravenna-tx-fix/*.patch`, `history/aes67/ravenna-lead-export/*.patch` | GPL-2.0-only | Patches to the RAVENNA ALSA kernel module (`MODULE_LICENSE("GPL v2")`) from aes67-linux-daemon. |
| `dante/patches/*.patch` | GPL-3.0-or-later | Patches to [Inferno](https://github.com/teodly/inferno), dual-licensed GPL-3.0-or-later / AGPL-3.0-or-later upstream; offered here under GPL-3.0-or-later. |

Notes:

- Upstream checkouts (`history/aes67/aes67-linux-daemon/`, `dante/upstream/`)
  are not part of this repository; they keep their own licences
  (aes67-linux-daemon GPL-3.0, Inferno GPL-3.0-or-later / AGPL-3.0-or-later,
  Statime Apache-2.0 / MIT).
- `usb16x16-dante-owner` is Apache-2.0. At run time ALSA loads the Inferno
  plugin (GPL-3.0-or-later) into it; Apache-2.0 is compatible with GPL-3.0, and
  anyone distributing that combination as one work takes on the GPL-3.0's
  obligations for it.
- `history/installers/dante/service/owner-capture-fault.patch` patches this project's
  own owner and is Apache-2.0.
- The binaries under `dsp-core/artifacts/` are built from this
  repository's own sources (Apache-2.0).
