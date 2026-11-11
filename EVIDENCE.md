# Where `outputs/` went

The measurement evidence (`outputs/latency/`, `outputs/dsp-verify/`,
`outputs/dsp-service/`, `outputs/screenshots/`: about 10,000 files) moved on
2026-11-10 to its own repository, with its history:

**https://github.com/squeaksquad/USB-AoIP-evidence**

`PROJECT_HANDOFF.md` and the design documents cite it as `outputs/...`. To
make those paths resolve in place, clone it as `outputs/` in this checkout
(the directory is ignored here):

```bash
git clone https://github.com/squeaksquad/USB-AoIP-evidence outputs
```

The measurement tools (`dante/measure-candidate.sh`, `tools/latency-harness/`,
`dsp-compiler/run-*.sh`) write new results under `outputs/`; commit them in
that repository.

Files that left `outputs/` for this repository instead:

| Old path | Now |
|---|---|
| `outputs/latency/usb-holes-20260904/zeros.py` | `tools/analysis/zeros.py` |
| `outputs/latency/usb-holes-20260904/gaps2.py` | `tools/analysis/gaps2.py` |
| `outputs/latency/rate-report-capture-20261029/channel-zeros.py` | `tools/analysis/channel-zeros.py` |
| `outputs/latency/rate44-live-20261028/set-rate-one.py` | `tools/analysis/set-rate-one.py` |
| `outputs/analyze-usb-channel-id.py` | `tools/channel-id/analyze-usb-channel-id.py` |
| `outputs/architecture.md` | `history/snapshots/architecture.md` |
| `outputs/pi-baseline.md` | `history/snapshots/pi-baseline.md` |

Nothing was removed from this repository's history: every `outputs/` path
still resolves at the tag `layout-2026-11-01`.
