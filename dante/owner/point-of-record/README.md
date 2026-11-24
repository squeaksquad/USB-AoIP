# The owner source of the point of record

`main.cpp` here is the owner's source as built for the installed, accepted
binary (`usb16x16-dante-owner` bb3cd6ca, the idle-phase owner with the
monitor block, accepted 2026-11-24): sha256 4d885b76, which is
`../main.cpp` at 8c9bf80e with `../idle-phase.patch` applied. The installer
builds this file with the headers and the bridge core kept beside it
(`*.hpp`, `bridge_core.cpp`, `usb16x16/bridge_core.hpp`): copies taken on
2026-11-24 of the files bb3cd6ca was built from (the bundle pinned by
`install/dev-unit/owner-idlephase.sha256`; bridge core 8a095aaa and
a1b6a05c). Every file here is pinned in `install/pins.sha256`.

Before 2026-11-24 this directory held the owner c84e6a36 ("ratepoll",
accepted 2026-11-01, commit c4b273d, main.cpp ec8d60bc) and the headers it
was built from; they are in the history (`git show 197945b:dante/owner/point-of-record/main.cpp`).

`../main.cpp` is the development line. Today it is the same file (4d885b76).
When a later owner is accepted, replace this file with its source, replace or
remove the copies beside it, and update `install/pins.sha256` and the owner's
build line in `install/install.sh`.

Do not edit these copies.
