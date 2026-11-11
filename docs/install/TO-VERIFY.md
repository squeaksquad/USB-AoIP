# To verify on hardware

What could not be checked without a Pi, for the operator to try. Written
2026-11-10 with the installer (workstream 2). Nothing here has been run on a
Pi. Strike items as they are tried, with the date and what happened.

## Before anything: four read-outs from the development unit

Read-only. They fill gaps in the record that the installer currently
guesses at (see `author-pi-mapping.md`, section 4).

1. `systemctl cat usb-16x16.service`: the base gadget unit, hash 99c87e86,
   is not in the repository. `gadget/usb-16x16.service` is a new unit written
   from what a oneshot around the script needs; compare the two.
2. `grep -v '^#' /boot/firmware/config.txt; cat /boot/firmware/cmdline.txt`:
   how the USB-C port is put in device mode. The installer adds
   `dtoverlay=dwc2,dr_mode=peripheral`; no such line is in the record.
3. `nmcli connection show aoip-eth0`: how the audio port gets its address.
   `AUDIO_IF_SETUP=link-local` creates a connection with
   `ipv4.method link-local`; the development unit's own is assumed, not known.
4. `sha256sum ~/usb-16x16-work/dante-mode/patches/000[345]-*.patch`: patches
   0003 to 0005 are pinned in `install/pins.sha256` from the repository's
   files; their hashes are recorded nowhere else, so this confirms the
   installed plugin c6b012ae was built from these.

## On the development unit (nothing changes)

5. `sudo install/install.sh adopt`, then compare `/etc/usb-aoip/install.conf`
   with `install/test/development-unit.conf`: they should be the same values.
6. `sudo install/install.sh status`: every file "as installed" (trivially,
   since adopt just hashed them), the units and start check reported.
7. `install/install.sh render --root /tmp/r --config /etc/usb-aoip/install.conf`
   then, for each file in `/tmp/r/manifest.rendered`, `cmp` it with the
   installed one. Expected differences, and no others:
   `usb16x16-dante-startcheck` (three lines, the config keys),
   `usb-16x16.service` (item 1), the new `20-thresholds.conf` drop-in and
   `startcheck.conf`, `asound-inferno-owner.conf` only if the unit is not at
   48 kHz, and `owner.conf` (the page's).

## On a second Pi, or a spare SD card in the same one

8. The whole of `docs/INSTALL.md`, sections 1 to 6. The steps marked
   *(unverified on hardware)*:
   - the kernel downgrade: whether removing the newer `linux-image-*`
     packages is what makes Raspberry Pi OS boot 6.18.34, and whether the
     installer's printed commands are right;
   - the `dtoverlay` line and the reboot producing `/sys/class/udc/1000480000.usb`;
   - `AUDIO_IF_SETUP=link-local`.
9. DKMS on the Pi: `dkms status` shows `usb-aoip-uac2/1.0` installed for the
   running kernel; `modinfo -F filename usb_f_uac2` is under `updates/dkms`.
   CI builds the modules against the same headers, but nothing has loaded
   one built this way. In particular, whether `dkms install` (and DKMS's
   automatic rebuild on a kernel change) accepts replacing an in-tree module
   without `--force`.
10. The built artifacts run: Statime locks to the leader, the device appears
    in Dante Controller under `DEVICE_NAME` with its own device ID, the host
    sees the gadget with the derived serial. The binaries will not hash to
    the development unit's (c84e6a36, c6b012ae, e1952224): compare behaviour,
    and record the new hashes from the manifest.
11. Two units on one host at once: distinct serials, both usable.
12. The web page as the dedicated `usb-aoip-web` user: it reads the journal
    (group `adm`), writes presets and apply requests under
    `/var/lib/usb-aoip`, and the applier acts on them. The unit's sandbox
    (`ProtectHome=read-only`, `ReadWritePaths=`) was written for a home
    directory.
13. `uninstall`, then `install` again: the Dante identity and subscriptions
    survive; `uninstall --purge` leaves nothing but packages.

## Acceptance

A fresh install builds its own owner, plugin and modules, so by the
project's rule it is a new operating point until measured: the noise probe
at 32 frames, four loaded 800-impulse runs and the ten-minute soak, against
the README's figures. The installer makes no claim that a second unit
measures the same; the render test only shows that its files are the same.
