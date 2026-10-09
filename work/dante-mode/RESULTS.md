# Dante mode results

Stage outcomes for [PLAN.md](PLAN.md). Revisions are in [SOURCES.lock](SOURCES.lock).

## Stage 2, part 1: source pin and read (2026-10-08, Mac only)

Scope: Inferno `dev` at 9767558e was cloned and read on the Mac. Nothing was
built (the Mac has no Rust toolchain), nothing was run, nothing touched the Pi.
Every line below is a reading of the source, not a measurement. The Statime
fork is pinned by branch head only and was not read. File references are
relative to `upstream/inferno/` at the pinned commit.

### Verdicts against the stage 2 gates

| Gate | Reading | Status |
|---|---|---|
| ALSA contract | mmap-interleaved, S32, 48 kHz, 16 channels, poll descriptor and a sample-resolution pointer are all present. Period and buffer sizes are powers of two only. | Compatible on paper with two bridge changes (sizes, prepare timing). Probe owed. |
| Transmit bit transparency | The default setting dithers 24-bit flows and alters the 24-bit LSB. `TX_SOURCE_BIT_DEPTH=24` removes the dither and leaves a plain truncation of the low byte. | Passes by configuration on paper. Sample-for-sample proof owed. |
| Thread creation | Threads are created at `prepare`, not at `open`, and are destroyed and recreated on every stop/prepare cycle. One further path can create threads on a network event. | Fails as written for a single process. See the consequence below. |

Consequence of the thread reading, by the rule the plan set: the endpoint
belongs in a separate owner process and the single-process bridge attempt in
stage 4 is skipped. This is the same process the plan already needs to keep
the Dante identity alive while USB is closed, so it removes a branch and adds
no new component. It does add one queue between the bridge and the network,
which stage 5 has to price.

### ALSA plugin contract (`alsa_pcm_inferno/src/lib.rs`)

- It is an ALSA ioplug with `mmap_rw = 1`. Access types offered:
  `MMAP_INTERLEAVED` and `RW_INTERLEAVED` (lines 755-764). Format: `S32` only
  (744-749). Rate: exactly `SAMPLE_RATE`. Channels: exactly `RX_CHANNELS` for
  capture and `TX_CHANNELS` for playback, fixed at open (781-799).
- Period sizes are powers of two from 16 to 32768 frames; buffer sizes are
  powers of two from 1024 to 65536 frames (812-848). The bridge asks for its
  period with `set_period_size_near` and refuses a buffer above 2048, so a
  period of 48 would silently become 32 or 64 and the only buffers on offer
  are 1024 and 2048. The capture buffer must also exceed the receive latency
  plus one period (upstream's note at 814).
- One process may open capture and playback and present one network device:
  both streams share one `DeviceServer`, keyed by device id (57-147).
- Poll: one eventfd per PCM, written by the Inferno transmit or receive thread
  at about half a period, and translated to `POLLIN`/`POLLOUT` (568-594,
  393-400). `DISABLE_POLLFD=1` removes it.
- Pointer: by default it is the media clock's current sample count minus the
  start time, computed on each call (187-233). It moves with sample
  resolution, not in period steps, and it advances whether or not any route
  exists. That satisfies the plan's "consistent network-paced timeline,
  including when no incoming routes exist". With `USE_FLOWS_CLOCK=1` it
  follows the network thread's last transfer position instead.
- Xrun: the pointer callback returns `-EPIPE` once the application is behind
  (268-286). Upstream's own FIXME there says recovery restarts the whole
  transmitter or receiver and gives a long break.
- `prepare` blocks: it waits for the clock in 250 ms sleeps for up to 5 s and
  returns `-ETIMEDOUT` if Statime is not answering (452-469). The bridge's
  recovery path calls prepare, so a clock loss turns a recovery into a stall
  of seconds.
- Logging: the plugin initialises `env_logger` in the host process with a
  default level of `debug` (645-655), written from the network threads. Set
  `RUST_LOG` explicitly; the bridge log on the SD card has already produced a
  RECOVER lattice once.

### Transmit and receive sample path

- The wire sample width is the receiver's choice, taken from its flow request
  (`inferno_aoip/src/device_server/flows_control_server.rs` 45, 114).
- With the default `TX_SOURCE_BIT_DEPTH=32`, a 3-byte flow is dithered: two
  random bytes are differenced, 128 is added, the sum is added to the 32-bit
  sample with saturation, and the top three bytes are sent
  (`samples_utils.rs` 58-67, `flows_tx.rs` 112-114, 129-130). For 24-bit audio
  carried in the top of S32 with a zero low byte, that changes the 24-bit LSB
  on a share of samples. It saturates and does not wrap.
- With `TX_SOURCE_BIT_DEPTH=24`, `should_dither(24)` is false and the top
  three bytes are copied unchanged. No gain or other arithmetic sits between
  the ALSA buffer and the packet (`flows_tx.rs` 159-190).
- Receive places the three wire bytes in the top of S32 with a zero low byte
  (`samples_utils.rs` 87-93). No arithmetic.
- Missing samples are sent as zeros without an error line; the log call is
  commented out (`flows_tx.rs` 162-173). A late bridge write is therefore
  silent zeros on the wire, which is the 41-sample-hole class of fault. The
  continuous-signal check in stage 3 is what will see it.

### Threads (the mlockall concern)

Created inside whichever process opens the PCM:

| Thread | Created | Scheduling | Source |
|---|---|---|---|
| `Inferno main` (single-thread async runtime: control servers, subscriptions, clock client) | first `prepare` of either stream | default | `lib.rs` 73, `util/thread.rs` |
| mDNS broadcaster, mDNS discovery | device start, on the first prepare | default | `searchfire/src/broadcast.rs` 111, `discovery.rs` 157 |
| `flows RX` | every capture `prepare` | SCHED_FIFO, priority hint 80 | `flows_rx.rs` 500, 195 |
| `flows TX` | every playback `prepare` | SCHED_FIFO, priority hint 81 | `flows_tx.rs` 512, 275 |

- `prepare` on a stream that is already running stops it and starts it again
  (`lib.rs` 406-431), which joins the old network thread and creates a new
  one. Every bridge recovery that re-prepares an Inferno PCM is a thread
  creation while USB capture runs.
- Route changes in Controller do not create threads: flows are added by
  message to the existing threads and the `tokio::spawn` calls are tasks on
  the existing runtime.
- Not settled by reading: `searchfire/src/discovery.rs` 362 hands mDNS
  discovery events to the runtime's blocking pool, which creates threads on
  demand and retires them when idle. Whether Inferno's lookups reach that
  path was not traced. The probe decides it.
- Stack size is the Rust default (2 MiB) for each; none sets its own. The
  real-time priority call's result is discarded, so a missing rtprio limit
  leaves the network threads at normal priority without a message.
- The bridge's real-time thread and Inferno's two would be three SCHED_FIFO
  threads sharing the Pi's cores; their pinning is unassigned.

### Latency settings as wired, which is not as documented

- `RX_LATENCY_NS` (default 10 ms) is stored as the device's `latency_ns` and
  is what mDNS advertises to other devices, with upstream's comment "FIXME
  should be tx latency" (`settings.rs` 110-113, `mdns_server.rs` 119, 188).
- `TX_LATENCY_NS` (default 10 ms) is what the receive side uses as its minimum
  latency, with upstream's comment "FIXME should be RX latency"
  (`device_server/mod.rs` 255, `channels_subscriber.rs` 807). Effective
  receive latency is the larger of that and the transmitter's advertised
  minimum.
- On transmit through the ALSA plugin the send latency is hard-coded to zero
  and `TX_LATENCY_NS` only bounds how stale a sample may be before the flow is
  re-timed (`flows_tx.rs` 512-520). Packet timestamps carry a fixed -0.5 ms
  offset (`CLOCK_OFFSET_NS`, line 45).
- So the two knobs are crossed in this revision. Set both to the same value
  for the first tests, and when tightening, check which direction actually
  moved.
- Transmit timing is a thread sleeping until the next packet's timestamp and
  then sending everything due. Its jitter is the kernel's wake-up latency for
  that thread; there is no hardware-timed send.

### Clock

- Inferno does not read PTP itself. It receives a clock overlay (clock id,
  shift, frequency scale) from the Statime fork over a Unix datagram socket,
  default `/tmp/ptp-usrvclock`, or the path in `CLOCK_PATH`
  (`media_clock.rs`, `usrvclock-rs/src/lib.rs` 274).
- Which system clock the overlay sits on, and whether Statime steers
  `CLOCK_REALTIME` on the Pi, is in the fork's configuration and was not read.
- The media clock has a commented-out guard against jumps
  (`media_clock.rs` 41-50), so an overlay jump reaches the pointer and the
  transmit timestamps directly. A jump beyond 192000 samples re-times the
  flows; a smaller one does not.

### Identity and state

- `DEVICE_ID` defaults to the IPv4 address plus `PROCESS_ID`; `NAME` defaults
  to the executable name plus the address in hex (`settings.rs` 46-70). With
  `eth0` on a link-local address both must be set explicitly.
- `BIND_IP` accepts an interface name, so `eth0` can be named without
  recording its address.
- Saved subscriptions and names live in the platform state directory of the
  user running the process, under `inferno_aoip/<device id>`
  (`state_storage.rs` 22-24). For a root service that is under `/root`;
  `XDG_STATE_HOME` moves it.

### Settings the first probe should use

```
BIND_IP=eth0            NAME="USB 16x16 Inferno"     DEVICE_ID=<16 hex, fixed>
SAMPLE_RATE=48000       RX_CHANNELS=16               TX_CHANNELS=16
TX_SOURCE_BIT_DEPTH=24  RX_LATENCY_NS=TX_LATENCY_NS  RUST_LOG=warn
XDG_STATE_HOME=<durable directory under the work directory>
```

### Still owed for stage 2

1. Read the Statime fork at its pin: which clock it disciplines, its PTPv1
   configuration, hardware timestamping on the Pi 5's `eth0`.
2. Build on the Pi with `--locked`, service stopped, and record toolchain and
   artifact hashes in `SOURCES.lock`. Needs a test window.
3. The probe, without USB: mmap, poll, `avail`, `delay`, start, prepare,
   recovery and close as the bridge uses them, at periods 32 and 64 with
   buffers 1024 and 2048.
4. Bit transparency measured in both directions with `TX_SOURCE_BIT_DEPTH=24`,
   full scale included.
5. A thread trace across open, prepare, start, a route change, a forced xrun
   and close, to confirm the table above and to settle the blocking-pool
   question.
