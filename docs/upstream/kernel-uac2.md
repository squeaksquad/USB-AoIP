# The UAC2 gadget patches and upstream Linux

Status: a draft for the author to edit and send, or not. Nothing has been
sent anywhere. Written 2026-11-10 from a read of the four patches in
`kernel/`; none of this has been discussed with the gadget maintainers.

The four patches change `drivers/usb/gadget/function/` (`f_uac2.c`,
`u_audio.c`, `u_audio.h`) and are carried here against Raspberry Pi's
`6.18.34`. They apply in this order:

| # | Patch | What it does |
|---|---|---|
| 1 | `uac2-shared-clock-6.18.34.patch` | A function with both directions gets one clock source entity instead of two; a SET_CUR on it sets both rates; the two rate lists must match. |
| 2 | `uac2-discrete-channel-names-6.18.34.patch` | `bmChannelConfig` is 0 and `iChannelNames` points at sixteen consecutive strings `"1"`..`"16"`, so a host labels channels by number, not as speaker positions. |
| 3 | `uac2-rate-report-6.18.34.patch` | The `Capture Rate` / `Playback Rate` controls report the rate the host last set while the stream is idle too, until a disconnect or reset (`u_audio_forget_srate()`), with a control notification on each change. |
| 4 | `uac2-rate-request-6.18.34.patch` | A writable `Device Rate Request` control: the device moves its clock to a listed rate and sends the clock source's SAM_FREQ interrupt, so the host follows, as it would follow an interface on external clock. |

## Which look upstreamable

**3, rate report: yes, close to as it is.** It is self-contained and fixes a
real gap: userspace on the gadget cannot learn the host's chosen rate until
audio flows, so anything that must be configured for the rate first (here, a
network audio endpoint) has to guess. Points a reviewer will raise:

- It changes what an existing control reports. Today the control reads 0
  whenever the stream is stopped (check what
  `Documentation/usb/gadget-testing.rst` says of it). Software that treats 0 as
  "stream stopped" would see a rate instead. The honest options are to argue
  the new meaning is the useful one and update the document, or to leave the
  existing controls alone and add a second pair (`Capture Host Rate`). Expect
  to be asked for the second.
- `f_uac1` uses `u_audio` too and should call `u_audio_forget_srate()` on
  disable, or the commit message should say why not.

**1, shared clock: yes, as an option.** As written it changes the descriptors
of every duplex UAC2 gadget unconditionally, which would change what existing
products enumerate as. It needs a configfs attribute (say `shared_clock`,
default 0), an entry in `Documentation/ABI/testing/configfs-usb-gadget-uac2`
and in `gadget-testing.rst`. The motivation is strong and easy to state:
macOS treats two clock sources as two independently clocked devices and will
not present the function as one duplex device at a single rate.

**4, rate request: yes, after 1.** It only works with the shared clock as
written (`clk_id` is set only then) and it needs the interrupt endpoint that
exists only when a volume or mute control is enabled (`agdev->notify`). To go
upstream it wants: one control per clock when the clocks are separate; the
interrupt endpoint created when this feature is enabled, not as a side effect
of volume; documentation; and the reference to this project's
`RATE_REPORT_PLAN.md` taken out of the comment. Tested here against macOS
only (idle and streaming); a reviewer will ask what Windows and Linux hosts
do with a SAM_FREQ interrupt.

**2, channel names: not as it is.** It hard-codes sixteen names and zeroes
`bmChannelConfig` for everyone. The upstreamable form is a configfs option:
either a flag for "discrete, numbered channels" that generates one string
per channel for the configured channel count, or attributes carrying the
names. The existing `c_it_ch_name` / `p_it_ch_name` attributes name only the
first channel, which is the thing to build on. This is a rewrite, not a
rebase.

## Before sending

- Rebase onto the USB tree's `usb-next` (the patches are against a Raspberry
  Pi vendor tree; `f_uac2.c` moves often enough that offsets will differ).
- One logical change per patch, each with a `Signed-off-by:` from the author
  under the Developer Certificate of Origin, a commit message in the kernel's
  form (`usb: gadget: f_uac2: ...`), and `scripts/checkpatch.pl --strict`
  clean.
- Recipients from `scripts/get_maintainer.pl`, which will give
  `linux-usb@vger.kernel.org` and the USB gadget maintainer; add the people
  who wrote the rate controls and the feature-unit interrupt in `u_audio.c`
  (from `git log` on the file).
- Send 1 and 3 first as a short series. 4 depends on 1; 2 is a separate
  later patch.

## Draft cover letter (series of 1 and 3, with 4 as RFC)

```
Subject: [PATCH 0/3] usb: gadget: f_uac2: shared clock, host rate while idle, device rate request

This series comes from running a 16-in/16-out UAC2 gadget on a Raspberry
Pi 5 as a bridge between a macOS host and an audio network, where the
gadget side has to follow the host's sample rate and the host has to
follow the network's.

Patch 1 adds a configfs option, shared_clock, for functions that have both
capture and playback. With it set the function exposes one clock source
entity for both directions instead of two, and a SET_CUR on that clock
sets both rates. Without it nothing changes. Hosts that model each clock
source as a separate clock domain (macOS does) otherwise will not treat
the function as a single duplex device.

Patch 2 lets userspace on the gadget read the rate the host has set
before a stream starts. Today the Rate controls read 0 until the stream
is active, so a consumer that must be configured for the rate before
audio flows cannot be. The host's rate is now reported from SET_CUR until
the host goes away (disconnect, reset, new configuration), with a control
event on each change. [Say here which of the two forms was chosen: the
existing controls changed and gadget-testing.rst updated, or new controls
added beside them.]

Patch 3 (RFC) adds the other direction: a writable "Device Rate Request"
control. Writing a rate from the function's list moves the device's clock
to it and sends the clock source's SAM_FREQ interrupt, as a device locked
to an external clock would. macOS then re-reads the clock and changes the
device's nominal rate, idle or streaming. It is RFC because it has only
been tested against macOS and because it needs the interrupt endpoint
that is currently created only for volume/mute.

Tested on a Raspberry Pi 5 (dwc2, high speed) against macOS [version],
16 channels each way, 24-bit, 44.1/48/88.2/96 kHz.

[author] (3):
  usb: gadget: f_uac2: add shared_clock option for duplex functions
  usb: gadget: u_audio: report the host's sample rate while idle
  usb: gadget: u_audio: add Device Rate Request control

 Documentation/ABI/testing/configfs-usb-gadget-uac2 |  1 +
 Documentation/usb/gadget-testing.rst               | ..
 drivers/usb/gadget/function/f_uac2.c               | ..
 drivers/usb/gadget/function/u_audio.c              | ..
 drivers/usb/gadget/function/u_audio.h              | ..
 drivers/usb/gadget/function/u_uac2.h               | ..
```

The bracketed parts and the diffstat are to be filled in from the rebased
series. The macOS version and the exact host behaviour should come from
`docs/design/kernel/RATE_REPORT_PLAN.md`, which records the experiment.

## The Inferno patches

`dante/patches/0001`..`0005` are against Inferno (GPL-3.0-or-later), not the
kernel. 0002 (retry subscriptions after 1 s) and 0003 (`MSG_CONFIRM` on the
transmit flows so the neighbour entry for a receiver that ignores unicast ARP
never fails) fix behaviour any Inferno user could hit and are the ones worth
offering to that project; 0001 (`XRUN_REPORT`), 0004 (rate status) and 0005
(rate request handed to an external arbiter) are more specific to this
device and would need discussion with its maintainer first. Not drafted
here.
