# UAC2 discrete channel labels

Status: complete and installed on 2026-09-01. macOS verified one native
`USB 16x16` duplex device at 48 kHz with input and output labels `1` through
`16`. The installed module SHA-256 is
`87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e`;
`usb-16x16.service` and `setup-usb-16x16` were not changed.

This exact-source patch retains the validated shared UAC2 clock and the
`p_chmask=65535` / `c_chmask=65535` endpoint configuration, but advertises
`bmChannelConfig=0` instead of sixteen spatial speaker bits. Both terminal
descriptors point to a consecutive USB string block named `1` through `16`.

The installed module is not modified by the build. Artifacts:

- `uac2-shared-clock-6.18.34.patch`: the already-validated shared-clock patch.
- `uac2-discrete-channel-names-6.18.34.patch`: the additive label patch.
- `usb_f_uac2-discrete-channels.ko`: experimental module, SHA-256
  `87989337bbfb7d39298bf44c2a4fb5e592b9ff03dc671f4fbfb9af62e8778b1e`.
- `test-on-pi.sh`: bounded foreground test with automatic baseline rollback.

The test deliberately interrupts USB enumeration. Run only while the AES67
stack is stopped. Copy the module and test script to the Pi, then run the test
with passworded sudo. During the printed test window, verify both directions in
Audio MIDI Setup and Pro Tools. Ending the script or pressing Control-C restores
the installed known-good module and requires `configured/high-speed` again.

Do not install the experiment persistently until macOS proves that it both
retains one native 16x16 duplex device and uses the requested labels. Some hosts
may ignore `iChannelNames`; `bmChannelConfig=0` should still remove speaker roles.

The 2026-09-01 bounded experiment passed that descriptor check in both
directions. `install-on-pi.sh` performs the persistent transition without
changing `usb-16x16.service` or `setup-usb-16x16`. It accepts only the exact
verified old and new module hashes, retains the old module beside the installed
one as `usb_f_uac2.ko.pre-discrete-channels`, and automatically restores it if
the new module does not return configured/high-speed USB within 20 seconds.
