# To verify on hardware

What could not be checked without a Pi, for the operator to try. Written
2026-11-10 with the installer (workstream 2). Nothing here has been run on a
Pi. Strike items as they are tried, with the date and what happened.

## Before anything: four read-outs from the development unit

**DONE 2026-11-13.** The operator ran all four; each confirmed the guess or
replaced it (handoff entry of that date):

- item 1: the base unit is now in the repository as
  `history/installers/gadget/usb-16x16.service`, and it hashes to 99c87e86.
  The fresh-install unit was aligned with its ordering.
- item 2: `[all] dtoverlay=dwc2,dr_mode=peripheral`, the line the installer
  adds. Nothing gadget-related in `cmdline.txt`.
- item 3: `aoip-eth0` is `ipv4.method link-local`, `ipv4.never-default yes`,
  `ipv6.method link-local`, autoconnect; the installer now sets
  never-default too.
- item 4: the staged patches 0003, 0004 and 0005 hash to the pinned values.

The original list, for the record:

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

## On the development unit: the access update

`install/dev-unit/` (2026-11-13) puts the new page, web service 1.7.0 and
applier 1.9.0 on the unit the old chain built, with a rollback. Tested
against a stand-in root only.

7a. On the Mac: `install/dev-unit/stage-access.sh`, copy the bundle over (not
    during a measurement), then on the Pi `./install-access.sh status` and
    `sudo ./install-access.sh install`. It prints the acceptance steps: the
    page's checks, an Apply and back, a live edit and Commit, a rate move
    from each side, then the noise probe and `soak 120 32`.
7b. What only the Pi can show: the web service starts under its tightened
    unit (the log panel through group `systemd-journal`, temperature through
    `vcgencmd`), the path unit fires on a file renamed into the inbox, and
    the applier's status reaches the page from `/var/lib/usb16x16-apply`.
7c. `sudo ./install-access.sh rollback` if anything is wrong; then tell the
    session what failed.

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

## The web page and access (workstream 3)

Built 2026-11-10; unit-tested and looked at in a browser against a mock
stack, never run on a Pi.

14. The request path end to end as two accounts: the page (as
    `usb-aoip-web`) drops a request in `/var/spool/usb-aoip/inbox`, the path
    unit fires on it, the applier (root) acts and writes
    `/var/lib/usb16x16-apply/current.json`, the page shows the result. Try
    Apply, a live edit, Commit and Shut down. The inbox mode (1730) and the
    `PathChanged=` trigger on a directory are the parts only a real systemd
    can show.
15. From the web account, try to misuse the inbox: `ls` it (must fail),
    plant a symbolic link named `<id>.request` pointing at a root file (the
    applier must refuse it and leave the target alone).
16. TLS: the certificate is made, the fingerprint the installer prints
    matches the browser's, the page loads over `https://`, plain `http://`
    to the same port fails. Change the Pi's address and run `install`: a new
    certificate.
17. The page with no address on `MGMT_IF` at boot: the service exits and is
    restarted until the address is there (`systemctl status usb16x16-web`).
18. The page's sandbox additions do not break it: the log panel (group
    `systemd-journal`), temperature and throttling (`vcgencmd`), meters.
19. The new status on the page against a real unit: the device name, the
    rate after a rate change, the "Network audio check" row through a start,
    and the notices when the Dante service is stopped by hand.
20. `PTP_SANDBOX=1`: see `docs/INSTALL.md`, "The clock service as an
    ordinary user". This one is a change to the audio path.
20a. `PTP_STATE=1`: the draft Statime patch. `cat
    /run/usb16x16-clock/port-state` should read `state=Slave ...` with a
    leader on the network; power the leader off and it should change
    (`Master` or `Listening`), and the page should show the warning within a
    few seconds; power it on again and it should return to `Slave`. Then the
    battery: this is a different Statime binary.
21. The applier and the web service are new builds of installed files
    (applier 1.9.0, web 1.7.0). By the 2026-10-29 rule: their behavioural
    checks above, a noise probe at 32 and one two-minute sixteen-channel
    soak. The rate arbiter's decisions were not changed, but it runs through
    the same file: a rate move from the Mac and one from Dante Controller.

## Acceptance

A fresh install builds its own owner, plugin and modules, so by the
project's rule it is a new operating point until measured: the noise probe
at 32 frames, four loaded 800-impulse runs and the ten-minute soak, against
the README's figures. The installer makes no claim that a second unit
measures the same; the render test only shows that its files are the same.
