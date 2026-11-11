# History

The research record: everything that led to the current product but is not
part of it. Nothing here is needed to install or run USB-AoIP.

| Path | What it is |
|---|---|
| `aes67/` | The AES67 path (RAVENNA driver, `aes67-linux-daemon`, the supervisor service and its bridge binaries). It worked and was the rollback while Dante was developed; its service is stopped. |
| `installers/` | The incremental, hash-pinned installers that took the author's Pi from one accepted point to the next, with the files each one replaced. Superseded by the single installer. |
| `experiments/` | Candidate configs, probes, the Mac host-driver spike, the multi-rate gadget and kernel experiments, the DSP reference-validation tooling. |
| `snapshots/` | The 2026-08-30 architecture note and first Pi inspection. |

These files are kept as written. The scripts name their sibling files by the
layout the repository had until 2026-11-10, so they do not run from here: use
a checkout of the tag `layout-2026-11-01`. `work/MOVED.md` maps every old path
to its new one. `PROJECT_HANDOFF.md` at the top level is the dated log that
explains each of them.
