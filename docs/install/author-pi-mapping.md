# How the author's Pi maps onto the new installer

Status: for the operator to check, 2026-11-10. Read from the installer chain
in `history/installers/` and the product files only; nothing was read from
the Pi. Where the chain does not record something, it says so, and the last
section lists what has to be read off the Pi before `adopt` can be written.

The new installer keeps every installed path, unit name and binary name the
chain uses (`usb16x16-*`, `/etc/usb16x16/`, `/usr/local/libexec/usb16x16-dante/`),
so the Pi's files map one to one. Only the site-specific values inside them
move into `/etc/usb-aoip/install.conf`.

## 1. Config keys and the Pi's values

`adopt` would write exactly this file for the Pi and change nothing else.

| Key | The Pi's value | Fresh-install default | Where it is hard-coded today |
|---|---|---|---|
| `OPERATOR_USER` | `bdimaio` | the user who runs the installer | four sudoers rules; `usb16x16-dante-candidate` (`operator=`) |
| `WEB_USER` | `bdimaio` | `usb-aoip-web` (created) | `usb16x16-web.service` `User=`/`Group=` |
| `OWNER_USER` | `usb16x16-dante` | same | `usb16x16-dante.service`; created by `useradd --system` |
| `WORK_DIR` | `/home/bdimaio/usb-16x16-work` | `/var/lib/usb-aoip` | web unit (`web-ui`, `web-presets`, `web-auth`, `web-apply`), `usb16x16-apply.path` `PathChanged=`, applier and web defaults, candidate launcher |
| `AUDIO_IF` | `eth0` | `eth0` | Dante unit's carrier wait, `statime.toml`, Inferno `BIND_IP`, NetworkManager drop-in, start check, `stall-tuning.sh` IRQ pattern, catch tool, web default |
| `MGMT_IF` | `wlan0` | `wlan0` if it exists, else `AUDIO_IF` | web unit `--management-interface` |
| `WEB_PORT` | `8088` | `8088` | web unit `--port` |
| `DEVICE_NAME` | `USB-AoIP` | `USB-AoIP` | gadget product and control names, Inferno `NAME` |
| `USB_MANUFACTURER` | `Bryan DiMaio` | `USB-AoIP project` | `setup-usb-aoip` line 102 |
| `USB_SERIAL` | `AUDDEV001` | derived from the Pi's serial (`/proc/device-tree/serial-number`, last 8 hex digits, prefixed `UA`) | `setup-usb-aoip` line 101 |
| `USB_VID` / `USB_PID` | `0x1d6b` / `0x0104` | same (prototype IDs, see the script's own note) | `setup-usb-aoip` lines 96-97 |
| `USB_UDC` | `1000480000.usb` | first entry of `/sys/class/udc` | `setup-usb-aoip` line 31, `stall-tuning.sh` |
| `USB_RATES` | `48000,44100,88200,96000` | same | `setup-usb-aoip` line 23 |
| `DANTE_DEVICE_ID` | `88a29e8b01e40000` | `AUDIO_IF`'s MAC followed by `0000` | Inferno config line 68 |
| `DANTE_STATE_ID` | `5553423136783136` | same | Inferno config line 69 |
| `DANTE_RATES` | `44100,48000,88200,96000` | same | Inferno config `SUPPORTED_SAMPLE_RATES` |
| `KEEPALIVE_TARGETS` | `192.168.1.58 192.168.1.67` | empty: the keepalive unit is not installed | `usb16x16-wlan-keepalive.service` |
| `KERNEL_PIN` | `6.18.34+rpt-rpi-2712` | see section 3 | kernel build and install scripts |

Keeping `USB_SERIAL=AUDDEV001`, `USB_MANUFACTURER=Bryan DiMaio` and the same
`DANTE_DEVICE_ID` on the Pi matters: macOS keys its saved device settings on
the USB identity, and Dante Controller keys subscriptions on the device ID
and name. A fresh unit gets its own.

Tuning that is already in config files of its own and stays there, with the
Pi's values as the shipped defaults:

| File | What it holds | Assumes |
|---|---|---|
| `/etc/usb16x16/dante/transport.conf` (= `dante/service/transport-rate882.conf`, add1bc21) | Every queue and buffer depth per rate, prime drop, capture drain, rate requests | One switch hop to the far device, a far device sending 1 ms packets, macOS's class driver on the host (the prime drop cancels a draw specific to it) |
| `/etc/usb16x16/dante/startcheck.conf` (new, optional) | `TOLERANCE=60`, `FLOOR=1000`, `SETTLE=45`, `WINDOW=10`, `FLOWS_TIMEOUT=180`, `MAX_RESTARTS=4`, `EPISODE=900` | That Dante audio is the only steady traffic of 128 bytes and over on the audio port; that the NIC has per-size receive counters (`ethtool -S`); that a lossy start is about 800 or 115 packets a second short, as on the development network; tolerance and floor measured at 48 kHz only |

Three of those start-check values (`tolerance`, `floor`, `episode`) are
constants in the script today; the others are already environment variables.
Making them keys means three one-line changes to
`usb16x16-dante-startcheck` (fccfdd62), defaults unchanged.

## 2. Installed files

What the chain leaves, and what the new installer writes at the same path.
"Same bytes" means the installer installs the repo file unchanged, so on the
Pi `status` will find the hash it expects.

| Installed path | On the Pi (sha256) | New installer |
|---|---|---|
| `/usr/local/libexec/usb16x16-dante/usb16x16-dante-owner` | c84e6a36, built from `main.cpp` ec8d60bc (commit c4b273d) | Built on the machine; hash recorded. See question 2 below |
| `/usr/local/libexec/usb16x16-dante/statime` | e1952224 | Built from `SOURCES.lock`; hash recorded |
| `/usr/local/lib/usb16x16-dante/alsa-plugins/libasound_module_pcm_inferno.so` | c6b012ae (patches 0001-0005) | Built from `SOURCES.lock` with the five patches; hash recorded |
| `/usr/local/libexec/usb16x16-dante/usb16x16-dante-start` | df6a1b0b | Same bytes |
| `/usr/local/libexec/usb16x16-dante/usb16x16-dante-startcheck` | fccfdd62 | Three lines changed (config keys), defaults identical |
| `/etc/usb16x16/dante/transport.conf` | add1bc21 | Same bytes; kept if already present |
| `/etc/usb16x16/dante/owner.conf` | applier-written | Shipped default only if absent |
| `/etc/usb16x16/dante/asound-inferno-owner.conf` | 85a5256f at 48 kHz | Rendered: `NAME`, `DEVICE_ID`, `STATE_ID`, `BIND_IP`, rates from config. With the Pi's values it must render to 85a5256f; the render test checks that |
| `/etc/usb16x16/dante/statime.toml` | 11b055df | Rendered: interface. Pi's values must give 11b055df |
| `/etc/systemd/system/usb16x16-dante.service` | 27b68877 | Rendered: interface in the carrier wait. Pi's values must give 27b68877 |
| `/etc/systemd/system/usb16x16-statime.service` | 01f1bebb | Same bytes in this workstream (workstream 3 proposes its sandboxing) |
| `usb16x16-dante-startcheck.service`, `usb16x16-dante-rate.{path,service}`, the four `10-usb-aoip.conf` drop-ins | e0ffc622, f3ec747c, a6971bae, ... | Same bytes except `Documentation=` lines that name `/home/bdimaio` |
| `/etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf` | 3a1842a6 | Rendered: interface |
| `/etc/sysctl.d/90-usb16x16-compaction.conf` | 2db7c8b9 | Same bytes |
| `/usr/local/sbin/setup-usb-aoip` | 65d26567 | Identity strings, rates and UDC read from config; everything else the same lines. With the Pi's values the configfs writes are identical; the render test checks the script's write list |
| `/etc/systemd/system/usb-16x16.service` | 99c87e86 (`history/installers/gadget/usb-16x16.service`, read off the Pi 2026-11-13) | `gadget/usb-16x16.service`: the same unit with the script named directly, no drop-in |
| `/etc/systemd/system/usb-16x16.service.d/10-usb-aoip.conf` | 91449df9 | Same bytes |
| `/lib/modules/<kernel>/updates/usb-16x16/{u_audio,usb_f_uac2}.ko` | ed539ca8, 505c6ad0 | DKMS puts its builds in `updates/dkms/`. `adopt` leaves the Pi's modules where they are and only records them |
| `/usr/local/sbin/usb16x16-stall-tuning`, `usb16x16-governor.service` | bde240b8, 00644010 | Tuning script rendered (IRQ patterns from config); unit same bytes |
| `/usr/local/bin/usb16x16-web`, `usb16x16-apply` | 6b98e7cf, 347a7062 | Same bytes in this workstream; their `/home/bdimaio` defaults are overridden from the units. Workstream 3 changes the access design |
| `usb16x16-web.service`, `usb16x16-apply.{path,service}` | f7c7d48c, 6d53b053, 23cb5b2e | Rendered: user, directories, interface, port |
| `/usr/local/libexec/usb16x16-dsp-offline` | 4492a19c | Built from `dsp-core`; hash recorded |
| Web UI and compiler modules | staged by hand to `~/usb-16x16-work/web-ui` | Installed to `/usr/local/share/usb-aoip/web-ui` (on the Pi, `adopt` keeps the staged directory) |
| `/etc/sudoers.d/usb16x16-{dante,dante-candidate,dante-catch,stall-tuning}` | name `bdimaio` | Rendered for `OPERATOR_USER`; the candidate and catch tools are development aids and are installed only with `--with-dev-tools` |
| `usb16x16-wlan-keepalive.service` | installed by hand, the Mac's two addresses | Rendered from `KEEPALIVE_TARGETS`; not installed when empty |

Not carried into a fresh install: the `*.previous` rollback copies in
`/usr/local/libexec/usb16x16-dante/` and beside the modules, the
`setup-usb-16x16-rates` and `setup-usb-16x16` scripts, and anything of the
AES67 stack. `adopt` does not touch them.

## 3. Two things found that need a decision

**The kernel patches do not apply to the kernel a fresh Raspberry Pi OS
installs today.** Checked 2026-11-10 against the upstream sources of each
release, with no fuzz allowed:

| Kernel | Patches |
|---|---|
| 6.18.34 (the Pi's) | apply; the result is byte-identical to the repo's saved `f_uac2.c.shared-clock` after the first two |
| 6.18.39 to 6.18.49 | apply |
| 6.18.50 and later (6.18.60 is what `linux-headers-rpi-2712` installs now) | `uac2-rate-request` is refused: `u_audio.c` gained an error path and a card-free callback upstream |

`linux-image-6.18.34+rpt-rpi-2712` and its headers are still in Raspberry
Pi's archive. So either the installer installs and holds that exact kernel
(the one every measurement was made on), or the rate-request patch is ported
to 6.18.50+ and becomes a new, unmeasured module.

**The repository's owner source is not the installed owner's.** The
installed binary c84e6a36 was built from `main.cpp` ec8d60bc (commit
c4b273d, 2026-10-30). `dante/owner/main.cpp` at HEAD is d4a39b8c (commit
16f4784, 2026-10-31), which adds the `--chan-holes` diagnostic used for the
96 kHz catch. With the option absent from the command line the audio path
should be the same, but that build was run as a candidate, not accepted as
the service's owner.

## 4. To read off the Pi before `adopt` or the install doc can be finished

**Read 2026-11-13** (handoff entry of that date): the base unit is
`history/installers/gadget/usb-16x16.service` (99c87e86); device mode is
`[all] dtoverlay=dwc2,dr_mode=peripheral` in `config.txt`; `aoip-eth0` is a
link-local, never-default connection; the running kernel is
`6.18.34+rpt-rpi-2712` (Debian `1:6.18.34-1+rpt1`). The package list and the
origin of `~/src/linux-6.18.34` were not read. What was asked:

None of these is recorded in the repository. All are read-only.

```bash
systemctl cat usb-16x16.service
```

```bash
grep -v '^#' /boot/firmware/config.txt; cat /boot/firmware/cmdline.txt
```

```bash
nmcli -t -f NAME,TYPE,DEVICE connection show; nmcli connection show aoip-eth0 | grep -E 'ipv4\.|ipv6\.method|connection\.(id|interface-name|autoconnect)'
```

```bash
dpkg -l | grep -E 'linux-(image|headers)|dkms|libasound2-dev|ethtool|cmake'; ls ~/src; cat /sys/class/udc/*/uevent 2>/dev/null | head; ls /sys/class/udc
```

What each answers: the base gadget unit (hash 99c87e86, only its hash is in
the handoff); how the USB-C port is put in device mode on this Pi (no
`dtoverlay=dwc2` or `dr_mode` appears anywhere in the record); how `eth0`
gets its link-local address (the NetworkManager connection `aoip-eth0` is
assumed by the drop-in but created by no installer); and which packages a
fresh install must add, including how `~/src/linux-6.18.34` got there.
