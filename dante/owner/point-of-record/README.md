# The owner source of the point of record

`main.cpp` here is the owner's source as built for the installed, accepted
binary (`usb16x16-dante-owner` c84e6a36, "ratepoll", accepted 2026-11-01):
commit c4b273d, sha256 ec8d60bc. The installer builds this file, with the
headers one directory up and `dsp-core/src/bridge_core.cpp`, none of which
have changed since.

`../main.cpp` is the development line: the same plus the `--chan-holes`
diagnostic (commit 16f4784), which ran as a candidate and was never accepted
as the service's owner. When a later owner is accepted, replace this file
with its source and update `install/pins.sha256`.

Do not edit this copy.
