# USB 16x16 / AES67 bridge

Start with [`PROJECT_HANDOFF.md`](PROJECT_HANDOFF.md). It is the authoritative project state and supersedes the older snapshots under `outputs/architecture.md` and `outputs/pi-baseline.md` where they conflict.

The verified USB implementation is a protected baseline. The AES67 bridge works as a manual 16x16 full-duplex prototype, including a clean 10-minute soak, but it has not yet been installed as a persistent service. The next priority is sample-accurate latency measurement and a sub-10 ms research program before final service packaging.

