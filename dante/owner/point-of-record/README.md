# The owner source of the point of record

`main.cpp` here is the owner's source as built for the installed, accepted
binary (`usb16x16-dante-owner` c84e6a36, "ratepoll", accepted 2026-11-01):
commit c4b273d, sha256 ec8d60bc. The installer builds this file with the
headers and the bridge core kept beside it (`*.hpp`, `bridge_core.cpp`,
`usb16x16/bridge_core.hpp`): copies taken on 2026-11-18 from d05d402, where
they were still the files c84e6a36 was built from (bridge core bbaec39e and
c8558c99). The development line one directory up and in `dsp-core/` has
moved on since (the monitor block, phase 3 of the page redesign), so the
installer no longer reads it for the owner. Every file here is pinned in
`install/pins.sha256`.

`../main.cpp` is the development line: the same plus the `--chan-holes`
diagnostic (commit 16f4784), which ran as a candidate and was never accepted
as the service's owner. When a later owner is accepted, replace this file
with its source, replace or remove the copies beside it, and update
`install/pins.sha256` and the owner's build line in `install/install.sh`.

Do not edit these copies.
