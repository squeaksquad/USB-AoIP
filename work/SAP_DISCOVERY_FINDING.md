# SAP discovery timeline: the delay is a fixed ~264 s network timer, not the daemon

Status: resolved on 2026-09-01. The daemon-side split is n=13, the
return-signal turn-on n=7, and the Mac-side SAP capture n=2. The analysis was
derived from already-committed data; run `143219Z` was then run against the new
instrumentation build and reproduced every prediction.

**This supersedes the previous revision of this document, which concluded that
the Pi took ~282 s to announce and that Ferrofish resolution was fast. Both
conclusions were wrong.** They rested on treating the Mac's SAP capture as a
record of when the Pi *sent* an announcement. It is not; it records when the
Mac's switch port was *delivered* one. The daemon's own log, already committed
in every `phase4-candidate-*` directory, settles the difference.

## What the daemon log shows

The Pi announces at **T0 + 42.4 s**, not T0 + 282 s. Sampled over all twelve
committed candidate runs, the startup is deterministic to within ~100 ms:

| Phase | Duration | n=12 spread | Nature |
|---|---:|---|---|
| ssh, wrapper preflight, `insmod`, daemon exec | 0.35 s | — | legitimate |
| daemon init: interface, IGMP joins, HTTP bind, sources added | 1.00 s | ±0.004 | legitimate |
| PTP `unlocked` -> `locked` | 9.00 s | ±0.003 | fixed dwell, see below |
| wrapper detects lock, `PUT /api/sink/0`, SDP parsed | 0.18 s | 0.165-0.199 | legitimate |
| **first sink's `add RTP stream` blocked inside the RAVENNA LKM** | **31.88 s** | **31.849-31.927** | **target** |
| first current-version SAP announcement | at **T0 + 42.40 s** | 42.036-42.105 | |

Legitimate startup, module load, and PTP lock together account for **10.5 s**.
The remainder the task predicted — daemon ready but not yet announcing — is
**31.9 s**, and it has a single identified cause.

### The 31.9 s stall is one driver call, and only ever the first one

The sink thread logs, unchanged in all twelve runs:

```text
09:41:29.204674  session_manager:: using SDP
09:41:29.204827  session_manager:: media 0 sink addr 239.69.121.9:5004
09:41:29.204842  session_manager:: media 0 playout delay 576
          <-- 31.849 s, nothing logged, by any thread -->
09:42:01.054173  driver_manager:: add RTP stream success handle ...
09:42:01.054230  igmp:: joined multicast group 239.69.121.9
09:42:01.054262  session_manager:: added sink 0
```

The gap sits entirely inside the driver call that creates the RX stream.
Measured per direction, per run:

| | sink 0 | sink 1 | sources 0 and 1 |
|---|---:|---:|---:|
| add-stream duration | 31.85-31.93 s | 0.000 s | 0.000 s |

So it is not "adding streams is slow." It is a **one-time initialization
inside `MergingRavennaALSA` on the first RX stream created after `insmod`**.
Transmit streams do not pay it. The second sink does not pay it.

### It also delays the announcement, by 11 s

The SAP thread logged `next SAP announcements in 30 secs` at +1.00 s, so it
intended to announce at +31.0 s. It logged nothing at +31.0 s and then fired at
+42.05 s — within 200 microseconds of `added sink 0`, in all twelve runs. It was
not idle-looping with nothing to announce; it was blocked on the same
`session_manager` lock the add-sink call holds. Cost to discovery: **11.05 s**
of the 31.88 s stall. The other ~20.8 s hides behind the 30 s announcement
timer, but is still fully on the critical path for the RX direction, which has
no sinks until the call returns.

### Two smaller daemon-side items, noted not chased

- **PTP "lock" takes exactly 10.00 s** in all twelve runs (10.002-10.005).
  A real acquisition would vary. This is a fixed dwell somewhere in the daemon
  or the driver, not measured convergence.
- **The first announcement is deferred a full 30 s interval.** The daemon can
  announce immediately — in ten of the twelve runs it announces *stale* sessions
  restored from `status.json` at +1.0 s, then re-announces current versions and
  deletes the stale ones at +42 s. Current-version sources became announceable
  ~10 ms after the +1.0 s tick and so missed it.

## What the other 240 seconds actually is

The Pi announced nine times before the Mac received one:

```text
09:42:01  09:42:31  09:43:01  09:43:31  09:44:01     <- sent, not delivered
09:44:31  09:45:01  09:45:31                         <- sent, not delivered
09:46:01                                             <- sent, and received
```

**240.0 s** in which the Pi was announcing every 30 s and the Mac received
nothing. That is not a daemon target and no daemon change will shorten it.

### The return audio came up before the Mac saw any SAP at all

`readiness-probe-*.json` dates the audio path independently of SAP. Probes 1-47
report `capture contains no signal at any candidate impulse lag`. Probe 48 is a
clean full-level detection — captured peak 0.247 against an impulse amplitude of
0.25, all 8 impulses found, correlation score 0.499.

| Event | T0 + |
|---|---:|
| last probe with no signal (p47) | 257.8 s |
| **first probe with return signal (p48)** | **262.8 s** |
| Mac's first SAP packet of any kind (Ferrofish) | 276.9 s |
| Mac's first SAP packet from the Pi | 282.4 s |

The audio path was up and correlating **14 s before the Mac received its first
SAP packet and 20 s before it received one from the Pi.** The previous
revision's "audio flowed 30 s after the Pi announced, so resolution is fast" was
reading a coincidence of the readiness gate (see below), not causation.

### The turn-on is a fixed timer, n=7

First probe with return signal, across every run that got that far:

| Run (T0, UTC) | 113600 | 120034 | 121252 | 124130 | 132355 | 134118 | 143219 |
|---|---:|---:|---:|---:|---:|---:|---:|
| first signal, T0 + | 263 s | 266 s | 265 s | 263 s | 267 s | 263 s | **263 s** |

Mean 264.3 s, full spread 4 s. `143219Z` was predicted at ~264 s before it ran
and landed on 263 s. Device-side subscription backoff does not look
like this. A fixed timer does.

**264 s is the IGMP group membership interval.** The standard value is
`robustness (2) x query interval (125 s) + max response time (10 s) = 260 s`,
and the Pi joins its groups at T0 + 0.35 s. The segment is link-local
(169.254/16) with a GS305EP and no router, so **there is no IGMP querier on it**.
With snooping enabled and no querier, the switch has no membership state to
maintain and withholds the groups until that interval expires, at which point it
falls back to flooding and everything works at once.

One cause explains both observations. Two ports — the Mac's (5) and the
Ferrofish's (2 or 3) — went from receiving nothing to receiving normally inside
the same ~20 s window, roughly 260 s after the Pi joined. Two independent
device-level backoffs landing there together is far less likely.

This is a hypothesis about the switch, formed without switch access. It is
consistent with every committed measurement, and it predicts a specific,
falsifiable A/B result (below).

### The n=2 SAP capture brackets the switch event tightly

Both runs behave identically, and together they bracket when forwarding starts.

| | run 134118Z | run 143219Z |
|---|---:|---:|
| Pi's daemon announces current versions | T0 + 42.4 s | T0 + 43.0 s |
| first return audio at the Mac | T0 + 263 s | T0 + 263 s |
| Mac's first SAP packet (Ferrofish) | T0 + 276.9 s | T0 + 267.9 s |
| Mac's first SAP packet (Pi) | T0 + 282.4 s | T0 + 282.3 s |
| Pi announcements sent but not delivered | 8 | 8 |

The Mac catches the Pi's **9th** announcement in both runs, because the Pi
announces on a 30 s tick from ~+43 s (+43, +73, ... +283) and forwarding starts
between 263 s and 268 s. Each source is then seen at its next scheduled
announcement — the Ferrofish sooner because it is on a different 30.5 s phase.
That is one switch-side event with two independent witnesses, twice.

## The readiness gate adds a variable 9-141 s on top

`measure-aes67-roundtrip.sh` gates on `peak >= 0.01` and
`max(perImpulseDelaySamples) - min(...) <= 2`. The spread test is coupled to the
shared drift estimator's convergence: 8 impulses at 250 ms span 1.75 s, and
while the estimator slews toward -33 ppm the delay moves ~1.5 samples/s, so ~2.6
samples of spread accumulate within a single probe. The gate can only pass when
the ramp momentarily rounds favourably.

Run 134118Z, probes 48-61: median latency falls monotonically 79.333 -> 77.646 ms
while the bridge slews `ppm` at its 2 ppm/s limit. Sample spread per probe
alternates 7, 2, 3, 10, 2, 10, 3, 3, 3, 3, 3, 2, 2, 2 — the PASS/FAIL pattern in
`settle.log` exactly. Gap from first signal to declared ready, per run: 141, 9,
55, 13, 22, 59, 100 s.

The gate is not wrong to be strict, but its timing is an artifact of SRC
convergence, not of the network. Do not read "ready after N probes" as when the
path came up; read `readiness-probe-*.json` for that.

## Corrected accounting of the 282 s

| Segment | Duration | Owner |
|---|---:|---|
| process start, `insmod`, daemon init, PTP lock, sink PUT | 10.5 s | legitimate |
| first RX stream add-stream stall in the RAVENNA LKM | 31.9 s | **daemon/driver target** |
| Pi announcing, switch not forwarding | 240.0 s | **network target** |
| **total to the Mac's first sight of a Pi announcement** | **282.4 s** | |

Of the 282 s, **11%** is a daemon-side target, **4%** is legitimate, and **85%**
is a switch behaviour that no amount of daemon work will improve.

If the switch forwarded multicast promptly, time to audio would be bounded by
the Pi's own 42.4 s announcement, minus whatever the two fixes above recover.

## Next measurements, in order

1. **IGMP snooping A/B — now has a prediction, not just a baseline.** With
   snooping disabled on the GS305EP, first-return-signal should collapse from
   264 s to roughly the Pi's announcement time plus one Ferrofish resolution
   interval. If it stays near 264 s, the switch hypothesis is wrong and the
   timer is inside the Ferrofish. Still blocked on identifying ports 2 vs 3, and
   still changes the network under test — every figure in the repo to date was
   collected with snooping enabled.
2. **Enable the IGMP querier instead.** If the diagnosis is right, this fixes
   the same 240 s without giving up snooping, and is the better production
   answer. Also switch-UI work, so also blocked.
3. **The 31.9 s first-RX-stream stall.** Fully on-Pi, not blocked by rack
   access. Worth an `insmod`-to-first-sink experiment to see whether the cost is
   per-`insmod` or per-daemon-start, and whether adding a throwaway sink early
   moves it off the critical path.
4. ~~**Repeat the Mac-side SAP capture.**~~ Done — run `143219Z`, n=2, and it
   agrees with n=1 to within 0.6 s on the daemon side and 0.1 s on the Mac's
   first sight of the Pi.

## AoIP segment inventory

Established by mDNS and ARP on `en12` ("2.5G AOIP").

| Device | Link-local IP | MAC | Switch port |
|---|---|---|---|
| Raspberry Pi (`eth0`) | 169.254.92.97 | `88:a2:9e:8b:01:e4` | 1 |
| Dante USB adapter `D2USB-6152f1` (Ultimo X2, 100 Mb) | 169.254.242.82 | `00:1d:c1:61:52:f1` | 4 |
| Mac (`en12`) | 169.254.227.116 | `4c:ea:41:63:33:8f` | 5 |
| Ferrofish `FF-PULSE-16-DX` / `P16DX-1d27dc` | 169.254.248.189 | `00:1d:c1:1d:27:dc` | 2 or 3 |
| Metric Halo ULN-2 3d `MobileIO_49057` | 169.254.162.191 | `00:07:59:00:bf:a1` | 2 or 3 |
| GS305EP management | 169.254.0.239 | `54:07:7d:20:48:50` | — |

Ports 2 and 3 are still unresolved between the Ferrofish and the Metric Halo.
The switch exposes no MAC table; identify by unplugging one cable and watching
the port status page, or by correlating per-port byte counters with generated
traffic. Resolve this before the snooping A/B, since interpreting a per-port
change requires knowing which port is which.

SAP announcements on this segment repeat about every 30.5 s. Allow a full
interval before concluding a source is silent.

## Method

The split was derived entirely from committed files. Run `143219Z` was then
executed against the instrumentation build to test the predictions, and is
included above.

- `outputs/latency/phase4-candidate-*/daemon.log` — daemon-side timeline, n=13.
- `outputs/latency/aes67-roundtrip-64f-*-api/readiness-probe-*.json` — audio-path
  turn-on and the SRC ramp, n=7.
- `outputs/latency/aes67-roundtrip-64f-{20260901T134118Z,20260901T143219Z}-api/sap-timeline.log`
  — Mac-side SAP reception, n=2.
- `bridge.log` has no timestamps but emits at 1 Hz (48000 frames per line),
  which is enough to place the drift estimator's first movement.

Mac and Pi wall clocks differ by about 36 ms, established by comparing send and
receive timestamps for the same SAP packets. That is negligible at this scale
and is ignored above.
