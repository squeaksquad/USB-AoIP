# Raspberry Pi 5 audio/AES67 baseline

Initial capture: 2026-08-30 between 18:56 and 19:01 EDT. PoE-only validation: 2026-08-30 at approximately 20:00 EDT. All inspection was read-only. The CamillaDSP prototype was staged under `/home/bdimaio/usb-16x16-work`; no system service, package, EEPROM setting, or kernel module was installed or changed.

## Executive result

- The verified USB gadget remains enabled, active, configured, and operating at USB High Speed.
- ALSA exposes one duplex `UAC2Gadget` PCM with exactly 16 capture channels and 16 playback channels.
- Both directions accept only 48 kHz packed 24-bit (`S24_3LE`) audio.
- CamillaDSP 4.1.3 opened and processed all 16 channels in both directions directly through ALSA for 60 seconds without a reported xrun or error.
- Wired `eth0` has a genuine hardware PTP clock and hardware transmit/receive timestamping. Wi-Fi does not.
- A 52Pi EP-0241 powered the Pi from a NETGEAR GS305EP over 802.3at Class 4 PoE. The Pi reached a stable idle state with no undervoltage/throttling history, while `eth0` negotiated 1 Gb/s full duplex and retained its precise hardware PTP capabilities.
- The current AES67/RAVENNA driver v2.1 source builds cleanly against the Pi's exact 6.18.34 kernel headers. It was not installed or loaded.
- Source inspection found that this RAVENNA driver does not consume the NIC's hardware timestamps or `/dev/ptp0`; its hardware-timestamp enable hook is a no-op and its PTP timestamp function reads a software/kernel clock. Treat it as an interoperability prototype until measured, not as proof that the Pi's PHC is used.

## Known-good USB invariant

| Item | Observed value |
|---|---|
| Kernel | `6.18.34+rpt-rpi-2712`, arm64, PREEMPT |
| USB service | `usb-16x16.service`: enabled and active |
| Gadget | `/sys/kernel/config/usb_gadget/studio_audio` |
| UDC state | `configured` |
| Link speed | `high-speed` |
| Active UAC2 module | `/lib/modules/6.18.34+rpt-rpi-2712/updates/usb-16x16/usb_f_uac2.ko` |
| Gadget setup script SHA-256 | `d3031e22192ad69bcc3d3a59c3b54898f3f5ff73973720643256a115e469afa3` |
| Service file SHA-256 | `99c87e86acf41676b89ae49267b45abd43b4ead58e871c92be97827e884ffa3d` |
| Custom UAC2 module SHA-256 | `8e9907d3363d80d3c93e8b24b5576e7dbd683cd6cb415580970364bc20c320e4` |

These three hashes were identical before and after the CamillaDSP tests and the AES67 driver compile-only test.

During the final Mac check, `system_profiler SPAudioDataType` anomalously returned an empty list for all Core Audio devices. This was not specific to the gadget: USB I/O Registry still showed `USB 16x16`, manufacturer `Bryan DiMaio`, serial `AUDDEV001`, both audio-streaming interfaces owned by Apple's `usbaudiod`, and a 480 Mb/s link. Recent Core Audio/USB Audio logs showed ongoing audio processing without a transport error. Reconfirm the normal Core Audio list before the channel-ID run.

## ALSA inventory

| Card | Function |
|---|---|
| `vc4hdmi0` | HDMI playback only |
| `vc4hdmi1` | HDMI playback only |
| `UAC2Gadget` | One playback PCM plus one capture PCM |

The production directions are:

- `hw:CARD=UAC2Gadget,DEV=0` capture: Mac USB output channels 1–16 entering the Pi.
- `hw:CARD=UAC2Gadget,DEV=0` playback: Pi audio sent to Mac USB input channels 1–16.

CamillaDSP's ALSA negotiation established the exact hardware constraints:

| Parameter | Capture | Playback |
|---|---:|---:|
| Channels | 16 only | 16 only |
| Rate | 48,000 Hz only | 48,000 Hz only |
| Format | `S24_3LE` only | `S24_3LE` only |
| Access | Interleaved | Interleaved |
| Negotiated period | 256 frames | 256 frames |
| Negotiated buffer | 4,096 frames | 4,096 frames |

The Pi user is a member of `audio`, so direct ALSA access does not require root. CamillaDSP reported real-time priority for its processing, capture, and playback threads even though the user's shell limits showed `RTPRIO=0`; this should be rechecked under the eventual system service identity.

## CamillaDSP proof

- Version: 4.1.3 (`05e9cfc`), official Linux aarch64 ALSA build.
- Downloaded artifact SHA-256: `d9a17092923ebfe5d20a770c6b6a7eb2268f9700f999bf604b9db09f518aca5a`.
- Configuration: direct 16×16 identity mixer, 48 kHz, `S24_3LE`, 1,024-frame processing chunks.
- Result: configuration validation passed; a 15-second verbose run and a 60-second normal run completed without an ALSA, CamillaDSP, or kernel error.
- Processing load observed during the verbose run: about 0.78% for the identity mixer.
- USB remained configured/high-speed after both tests.

This proves format compatibility and stable bidirectional processing. It does not yet prove channel numbering; the next test uses a deterministic one-channel-at-a-time 16-channel file.

CamillaDSP explicitly supports packed USB 24-bit as `S24_3_LE`; its asynchronous resampler and rate-adjust facility are appropriate where capture and playback devices use different clocks. See the upstream [ALSA backend documentation](https://github.com/HEnquist/camilladsp/blob/master/backend_alsa.md) and [CamillaDSP documentation](https://github.com/HEnquist/camilladsp/blob/master/README.md).

## Network and timestamping

| Interface | State | Driver | PTP/timestamp result |
|---|---|---|---|
| `eth0` | Carrier up; 1,000 Mb/s full duplex; IPv6 link-local reachable | `macb`, Raspberry Pi RP1 GEM | Hardware TX and RX timestamping; raw PHC; one-step transmit; `/dev/ptp0` |
| `wlan0` | Connected as `192.168.1.201/24` | `brcmfmac` | Software receive timestamping only; no PTP hardware clock |

`/dev/ptp0` is named `gem-ptp-timer` and is attached directly to `eth0`. The hardware advertises a precise IEEE 1588 timestamp provider and a maximum clock adjustment of 64,000,000 ppb.

Production AES67 must use wired `eth0`. Wi-Fi is suitable for SSH, management, and a GUI, but not for the media/PTP plane.

### PoE-only checkpoint

- HAT: 52Pi EP-0241, with no NVMe or PCIe configuration enabled.
- Switch: NETGEAR GS305EP port 1, configured for 802.3at with a 30 W port limit.
- Negotiation: Class 4, delivering power, no PoE fault.
- Switch telemetry at idle: 53 V, 64 mA, 3.4 W, 49 C PSE telemetry.
- Pi after 14 minutes: CPU 45.5 C; `vcgencmd get_throttled` returned `0x0`.
- Ethernet: link up, 1,000 Mb/s, full duplex; no ingress or egress rate limit.
- Pi Ethernet MAC: `88:a2:9e:8b:01:e4`.
- Link-local management address observed from the Mac: `fe80::8aa2:9eff:fe8b:1e4%en12`.
- USB preservation check: `usb-16x16.service` remained active and enabled. The UDC reported `not attached`, which is expected with USB-C physically disconnected.
- Timestamping recheck: hardware transmit/receive, precise raw hardware clock, and one-step transmit support remained present on `eth0`.

This validates the PoE HAT, switch negotiation, thermals at idle, wired link, and preservation of the known-good USB service independently. It is not yet a PoE load test, PTP lock test, or simultaneous PoE-plus-USB validation.

## Installed software and current services

Installed and relevant:

- ALSA utilities and libraries 1.2.14
- Avahi 0.8
- `ethtool` 6.14.2
- `alsaloop`
- NetworkManager and systemd-timesyncd

Not installed:

- CamillaDSP/CamillaGUI system services
- `linuxptp` (`ptp4l`, `phc2sys`, `pmc`)
- PipeWire, PulseAudio, JACK
- GStreamer or FFmpeg
- AES67 daemon/RAVENNA driver

This is a clean audio base: there is no desktop audio server competing for the gadget PCM.

## Clock and scheduling constraints

| Domain | Owner | Current fact | Required bridge behavior |
|---|---|---|---|
| USB audio | Mac/UAC2 transfer feedback | One shared UAC2 descriptor clock; both ALSA directions run at 48 kHz | Preserve; do not discipline the Mac or USB module from PTP |
| DSP | CamillaDSP | Runs from capture/playback ALSA timing | Use adaptive resampling whenever its two endpoints are in different clock domains |
| AES67 media | PTP grandmaster and AES67 endpoint | `eth0` has a suitable PHC, but no live PTP test yet | Endpoint must remain PTP-clocked; production implementation should explicitly use hardware timestamps |
| System time | systemd-timesyncd | NTP-disciplined system clock | Management only; not an AES67 media-clock substitute |

Current performance settings are prototype defaults:

- CPU governor: `ondemand`
- Kernel real-time bandwidth: 95% (`kernel.sched_rt_runtime_us=950000`)
- Locked-memory limit: 8 MiB
- Swap policy: `vm.swappiness=60`

Do not tune these globally until audio and PTP pass at defaults. Any production tuning must be one change at a time, measured, documented, and reversible.

## Compile-only AES67 driver check

The current upstream AES67 Linux daemon master was inspected at commit `77c97c34146f9a96d3479fd4d65792c7715d5492` (2026-08-21). Its RAVENNA ALSA driver `aes67-daemon` branch was checked at v2.1 commit `e8579da5b13960c0091e28d90bb75fc7489e780e`.

Driver v2.1 built cleanly against the exact installed Pi kernel headers:

- Module version: `bondagit-2.1`
- Vermagic: `6.18.34+rpt-rpi-2712 SMP preempt mod_unload modversions aarch64`
- Built module SHA-256: `f65a49558a0f8f16efbbe7afa45464d41529faacfcb1a838e897f99d9649604e`
- Includes `audio_cpu_affinity` and `jitter_buffer_multiplier` parameters.
- Module was not installed or loaded; only `usb_f_uac2` remained active.

The upstream daemon provides a PTP-clocked virtual ALSA device, RTP source/sink configuration, SDP, SAP, mDNS/RAVENNA discovery, and direct channel maps. See the [AES67 Linux daemon repository](https://github.com/bondagit/aes67-linux-daemon).

However, a source audit found no `SO_TIMESTAMPING`, `SIOCSHWTSTAMP`, PHC, or `skb_hwtstamps` integration. `EnablePTPTimeStamping()` returns success without configuring the NIC, and `GetPTPTimeStamp()` reads the driver's software/kernel timer. The daemon can still be valuable for interoperability and functional testing, but the existence of `/dev/ptp0` does not make this particular media engine hardware-timestamped.

## Immediate blocker

The wired/PoE physical layer now passes independently. Before reconnecting the Mac USB-C cable, resolve and validate the USB VBUS behavior required by the EP-0241's warning against simultaneous USB-C power. Then rerun the known-good 16x16 USB regression while monitoring PoE load, Pi throttling, and kernel errors. Address/VLAN policy, EEE, multicast behavior, PTP-grandmaster visibility, and live PTP lock remain untested.
