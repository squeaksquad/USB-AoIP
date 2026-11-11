# gadget/

The USB side: the UAC2 gadget the host sees as `USB-AoIP` (16 in / 16 out,
44.1 to 96 kHz, 24-bit).

| File | What it is |
|---|---|
| `setup-usb-aoip` | The configfs script `usb-16x16.service` runs. |
| `usb-16x16.service.d/10-usb-aoip.conf` | The drop-in that points the service at it. |
| `stall-tuning.sh`, `usb16x16-governor.service` | CPU governor and IRQ pinning. |
| `usb16x16-wlan-keepalive.service` | Keeps a Wi-Fi management path alive. Site-specific as written. |

The kernel modules the gadget needs are in `kernel/`. The original 48 kHz
gadget and its module are the protected rollback in
`work/protected-baseline-2026-08-31/`. Earlier gadget scripts and their
installers are in `history/installers/gadget/`.
