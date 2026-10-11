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

CORRECTION 2026-10-09 (source read for OWNER_DESIGN.md, not measured): the last
bullet below is wrong for the ALSA plugin. Its buffer is an `ExternalBuffer`,
read unconditionally (`inferno_aoip/src/ring_buffer.rs` 97-99, 393-396), so
the zero-fill branch of `flows_tx.rs` never fires: a late write is sent as
whatever the mmap ring holds at that timestamp, which is the audio of one
buffer length earlier, not zeros. See "Source read for the owner design" at
the end of this file.

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
- Which system clock the overlay sits on is answered in part 2 below.
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

## Stage 2, part 2: the Statime fork (2026-10-08, Mac only)

Scope: `teodly/statime` `inferno-dev` at 244f20a5 cloned and read. Not built,
not run. File references are relative to `upstream/statime/`. The fork's head
is from 2025-07-18, fourteen months older than the Inferno pin, and sits on
Statime 0.4.0.

### What it does to the Pi's clocks

With the shipped `inferno-ptpv1.toml` (`virtual-system-clock = true`,
`virtual-system-clock-base = "monotonic_raw"`, `usrvclock-export = true`):

- The clock PTP disciplines is an overlay, a shift and a frequency scale held
  in the daemon, not a kernel clock. Steering changes those two numbers and
  sends them to Inferno over the socket (`statime/src/overlay_clock.rs`
  133-155, `statime-linux/src/main.rs` 370-458).
- It is two overlays deep. An inner one sits on `CLOCK_TAI` and is held to
  `CLOCK_MONOTONIC_RAW` by its own Kalman loop, measuring in user space every
  250 ms and discarding any measurement that took over 1 ms (`main.rs`
  267-325). PTP steers the outer one.
- With software timestamps the daemon does not set, slew or step any system
  clock: the port's clock is the overlay, and the overlay ignores the time
  properties call (`overlay_clock.rs` 156-162). chrony or timesyncd need not
  be stopped for it to run. They still matter: packet timestamps arrive on
  `CLOCK_REALTIME`, so a step of system time during a run reaches the
  measurements. The fork's export guard against that is only built when the
  base is TAI (`main.rs` 377), not for `monotonic_raw`.
- With a hardware clock it does write. `hardware-clock = "auto"` is the
  shipped default; if `eth0` exposes a PHC the daemon opens it, may step it at
  start (`clock/mod.rs` 43-56), makes it the port clock so the PTP servo
  steers and steps the PHC itself, and couples it to the overlay with a second
  250 ms loop (`main.rs` 144-262, 496-514). That port clock's time properties
  call writes the TAI offset and leap flags to `CLOCK_REALTIME`
  (`clock/mod.rs` 167-181, called from `statime/src/port/bmca.rs` 281). Those
  are kernel-wide and outlive the process.

So the first run should set `hardware-clock = "none"`: it leaves no state on
the Pi beyond its socket file. Hardware timestamping is a second, separate
variable, with the PHC state and the TAI offset recorded before and after.

### Other readings

- PTPv1 is follower only, which suits the Ferrofish leading. The daemon binds
  the PTP event and general ports on the interface, the same ones the RAVENNA
  stack's PTPv2 uses, so the two cannot share `eth0`. This confirms the plan's
  rule to stop the AES67 stack first.
- It is a separate process, so its threads are no concern for the bridge's
  memory lock. It runs a multi-threaded runtime with one worker per core, at
  normal priority, unpinned and with nothing locked (`statime-linux/Cargo.toml`
  36, `main.rs` 336). Under the bridge's real-time threads its 250 ms
  measurements can be delayed; the 1 ms rejection then drops them. Its CPU
  affinity should be set from outside, off the bridge's core.
- Overlay steps go straight to Inferno, whose own jump guard is commented out
  (part 1). Upstream says the clock is unstable for a few seconds at start, so
  the owner process should open the PCMs only after the daemon has settled,
  and the probe should log every overlay update with its shift.
- The shipped configs set `loglevel = "trace"` and name the interface
  `enp0s31f6`. Both need changing: `warn`, and `eth0`.
- Whether the Pi 5's `eth0` offers a PHC and accepts a PTPv1 hardware filter
  is a fact about the Pi, not the source. `ethtool -T eth0` answers it and is
  read-only.

### First-run Statime config

```
loglevel = "warn"
sdo-id = 0
domain = 0
priority1 = 251
virtual-system-clock = true
virtual-system-clock-base = "monotonic_raw"
usrvclock-export = true

[[port]]
interface = "eth0"
network-mode = "ipv4"
hardware-clock = "none"
protocol-version = "PTPv1"
```

### Pi read, 2026-10-08 (operator, read-only)

- `ethtool -T eth0`: hardware transmit and receive timestamping with a raw
  hardware clock, provider index 0, "Precise (IEEE 1588 quality)". Transmit
  modes off / on / onestep-sync. Receive filter modes: `none` and `all` only.
- The fork asks for the `PTP_V1_L4_EVENT` receive filter in PTPv1 mode
  (`timestamped-socket/src/socket/linux.rs` 183), which `eth0` does not list.
  Whether the driver widens that request to `all` or refuses it was not
  established; it is seen only by trying it. If it refuses, hardware
  timestamps under PTPv1 need a one-line change to request `all`, as the
  fork's own layer-2 case already does (line 189).
- `chrony` inactive, `systemd-timesyncd` active. timesyncd disciplines
  `CLOCK_REALTIME`, which is where software packet timestamps come from, so
  it is the collision upstream warns about. For software-timestamp runs it is
  one more variable: record its state, and compare a run with it stopped
  before trusting clock stability figures. Stopping it is a root change on the
  Pi and needs its own go.

Both readings point the same way as the source: first runs on software
timestamps with `hardware-clock = "none"`, hardware timestamps later as their
own experiment.

### Toolchain check on the Pi, 2026-10-08 / 09 (read-only over ssh)

- Debian 13 (trixie), aarch64, 22 GB free on the root filesystem.
- First check: no `rustc`, `cargo` or `rustup` on the path, no `~/.cargo`, no
  Debian `rustc` or `cargo` package, and no `libasound2-dev`.
- The operator then installed `libasound2-dev` 1.2.14-1+rpt1 (dpkg log
  2026-10-08 21:30:39 EDT, 2026-10-09 01:30:39 UTC). `pkg-config` 1.8.1-4 is
  present. Re-checked afterwards: the ALSA headers are there, Rust is still
  absent (`~/.cargo/bin` included), and so are `clang` and `libclang-dev`.
  Whether the `alsa-sys-all` bindings need libclang at build time was not
  checked.
- The Mac has no Rust toolchain either, so nothing can be built anywhere yet.
- Service state at the time, for the record: `usb16x16-aes67.service` was up
  but the USB host was absent. The supervisor's host-absent detector had been
  cycling the bridge since the 20:00 EDT hour (episode 36 at 21:30:57 EDT,
  about 335 RECOVER lines a minute, all `ravenna-to-usb capture-ring-full`),
  which began before the install and before these checks. Nothing about
  bridge stability can be read from this window, in either direction.

### The probe (written 2026-10-09 UTC, compiled on the Pi, not run)

`probe/inferno-probe.c` drives the plugin with the bridge's own call set
(nonblocking open, `MMAP_INTERLEAVED`, S32, the same hardware and software
parameters, `poll`, `avail_update`, `delay`, `mmap_begin`/`commit`, `prepare`,
`start`, `drop`) and no USB. One run answers the three open gates:

- Contract: `NEGOTIATED` lines give what period and buffer were granted for
  what was asked; `PROBE` lines give, per second, wake count, the longest gap
  between wakes, capture `avail` and playback `delay` ranges, and frame counts
  from which the rate against `CLOCK_MONOTONIC_RAW` follows.
- Threads: a `THREADS` line at every lifecycle step (before open, after each
  open, hardware params, prepare and start, after each recovery, before and
  after each close, and again after a linger) lists every thread with its
  name, policy and priority, plus locked and resident memory. The set is
  re-read each second and any change while running is printed. `--mlock`
  runs it under `mlockall(MCL_CURRENT|MCL_FUTURE)` as the bridge runs.
- Bit transparency: each channel sends its own full-period 24-bit sequence in
  which every sample predicts the next, so the capture is checked sample for
  sample with no alignment. `VERIFY` lines give matches, mismatches, lost
  locks, runs of zeros, non-zero low bytes, both full-scale codes seen, and
  any channel that arrived on the wrong number. Full scale is covered after
  350 s. It needs each Pi transmit channel routed back to the same-numbered
  Pi receive channel through the Ferrofish's digital loop.
- `--xrun-at N` stops servicing both streams once and times the recovery.

`probe/run-probe.sh` wraps it on the Pi: application-scoped ALSA config
(`config/asound-inferno.conf`), the staged plugin, `RUST_LOG=warn`, state under
the work directory, log on tmpfs. It refuses while `usb16x16-aes67.service` is
active or when no Statime socket exists; it starts no daemon and uses no sudo.
`config/statime-first-run.toml` is the Statime config from part 2.

Staged on the Pi at `~/usb-16x16-work/dante-mode/{probe,config}/`:

```
0ccef1e855c2d31ab9c455adb4c7c8e81b1e35501dabcc80db77606574f0792b  probe/inferno-probe  (gcc -O2 -Wall -Wextra, no warnings)
fd0c6b0d1f0bc1dcca18447c6511e69debdd655049caf5a0fd4bcafd095b245d  probe/inferno-probe.c
c4b79d46eb380e5bd5cd30a0d2b5379203034f01e1b7390f088de604e7c71054  probe/run-probe.sh
eb9987f8f1a5d98d25211a1a585da7cedd337abf0ce04eecc4b2d38baac7ce9b  config/asound-inferno.conf
11b055dfca80e9a31357eb40a6417916c9522b26ca9f821fb6a71132e7922d71  config/statime-first-run.toml
```

### A further contract finding from writing it: the poll descriptor

The plugin's eventfd is only emptied inside its `poll_revents` callback
(`alsa_pcm_inferno/src/lib.rs` 577-588), which ALSA runs when the application
calls `snd_pcm_poll_descriptors_revents`. The bridge polls the raw descriptors
and goes straight to `avail_update`; it never calls that function. Against
this plugin its descriptor would stay readable after the first wake and the
loop would spin. Either the bridge-side code adds the call or the plugin is
opened with `DISABLE_POLLFD=1` and timed some other way. The probe's
`--no-revents` reproduces the bridge's behaviour and counts the spins, so the
reading can be confirmed.

Also read while writing: `snd_pcm_hw_params` prepares an ioplug itself, so the
network threads are first created inside the bridge's `configure()`, and its
explicit `prepare()` right after is already a stop-and-recreate.

## Stage 2, part 3: first probe runs (2026-10-09 01:50-01:53 UTC)

Conditions: `usb16x16-aes67.service` stopped; Statime started by the operator
as root with `config/statime-first-run.toml` at 01:50:19 UTC; probe run
unprivileged over ssh by `run-probe.sh`; no Dante routes made; period 64,
buffer 1024. Three runs: 20 s, 5 s with `--no-revents`, 5 s with a capture
dump. Logs are on the Pi's tmpfs (`/dev/shm/inferno-probe-*.log`) and were not
copied. These are short unprivileged runs: they settle the contract and the
thread lifecycle, not stability or latency.

Statime's terminal output, read against its source: `grandmaster unknown`
once (a delay request attempted before the first Sync had named the
grandmaster, `port/slave.rs` 700) and then `got DelayReq, master operation
not implemented yet for PTPv1` every few seconds (`port/mod.rs` 544). The
second is printed for every delay request any other PTPv1 follower multicasts,
whatever state this port is in; it is noise at `warn`, not a fault. Neither
line shows lock, and at this log level nothing does.

| Question | Measured |
|---|---|
| Sizes | period 64 and buffer 1024 granted as asked, both directions |
| Clock reaches the plugin | yes: `prepare` returned in under 1 ms, pointer ran at 48000 +/- 1 frames each second against `CLOCK_MONOTONIC_RAW` |
| Is that a PTP lock | not shown by these runs; a free-running overlay would read the same |
| Poll with the revents call | about 2,445 wakes/s, longest gap 0.72 ms, capture `avail` 0-35, playback `delay` 93-128 at a lead of 128 |
| Poll as the bridge does it | 1,025,000 wakes/s, every one a spin. Reading confirmed: the bridge loop would burn a core |
| Recoveries | none in any run |
| Open cost | first `hw_params` 251 ms (the device starts there); later calls under 1 ms |

Threads, as listed by the probe:

- None after `open`. Three appear inside the first `hw_params` (two named
  `Inferno main`, one `flows RX`), a fourth (`flows TX`) inside the playback
  `hw_params`.
- The explicit `prepare` that follows replaced `flows RX` (thread 19308 became
  19309) and `flows TX` (19310 became 19311). Stop-and-recreate on every
  prepare is confirmed.
- No change in the thread set over 20 s of running. The blocking-pool question
  is not settled by that: no route was made and no device came or went.
- After `close` all four were still alive; after a 12 s linger they were gone.
  Close returns before the device has shut down.
- All four ran SCHED_OTHER priority 0. The unprivileged shell has
  `ulimit -r 0`, so the plugin's request for SCHED_FIFO failed and, as read,
  said nothing.

Other observations:

- `--mlock` could not be tested unprivileged: under `mlockall` the open failed
  with -6. The shell's locked-memory limit is 8192 kB, 4256 kB was already
  locked before the open and the plugin is 6.9 MB, so the likely cause is the
  limit, not the plugin. It needs a run as root, as the bridge runs.
- Unrouted receive channels are not guaranteed silence. The dump held 469
  non-zero samples in 5 s, all on channel 11, two fixed values (0x00015981 and
  0x00011081) alternating at 292 and 732 frames, which sum to the buffer
  length: two fixed places in the ring, read once per lap. The 20 s run had
  the same once-per-lap pattern on channels 11 and 15. That is consistent
  with a capture buffer that is allocated unzeroed and never written where no
  flow exists; it was not traced further. The level is about -88 dBFS. An
  owner process should clear the capture areas itself before starting.
- Every run logged `unable to receive start time, ring_buffer addressing will
  be wrong!` and `unable to get start timestamp for ring buffer output` at the
  moment of the second prepare. They coincide with the first instance being
  torn down; whether they are only that was not established.
- Capture and playback each delivered 48000 frames a second throughout; the
  first second of playback carries the 128-frame lead.

### The same probe as root with the memory lock (01:55:15 UTC, run by the operator)

`sudo -E run-probe.sh --seconds 20 --mlock`, Statime unchanged, no routes.
Log `/dev/shm/inferno-probe-20261009T015515Z.log` on the Pi, read there.

- The open succeeded under `mlockall`, so the earlier -6 was the unprivileged
  locked-memory limit, as supposed.
- Real-time priority took effect: `flows RX` SCHED_FIFO 80 and `flows TX`
  SCHED_FIFO 81; the two `Inferno main` threads stayed SCHED_OTHER. Thread
  creation and the replacement at `prepare` were as in the unprivileged run.
- Memory under the lock, by lifecycle step:

  | Step | Locked (VmLck) | Resident (VmRSS) |
  |---|---|---|
  | before open | 4.3 MB | 4.1 MB |
  | after open (plugin loaded) | 9.2 MB | 9.0 MB |
  | after capture `hw_params` (3 threads) | 212.2 MB | 15.7 MB |
  | after playback `prepare` (4 threads) | 279.9 MB | 18.0 MB |

  Resident memory is what is occupied: about 2 MB per thread, which fits a
  fully populated 2 MiB stack each. The locked figure is roughly 68 MB per
  thread and is address space counted as locked, not memory in use; a
  per-thread allocator arena reservation would look like this, but that was
  not traced. On a 990 MB Pi the resident cost is small. The stack populate
  is the per-`prepare` cost the bridge rule is about: the playback `prepare`
  took 759 us here against 329 us unlocked.
- Timing was unchanged with the network threads at real-time priority: about
  2,490 wakes/s, longest gap 0.69 ms, capture `avail` 0-33, playback `delay`
  95-128, no recoveries, no thread-set change in 20 s. One second read 47,991
  frames and the next 48,009 where every other second was within 2 of 48,000;
  not explained.
- The unrouted capture channels held far more non-zero data than before:
  64,716 mismatching samples and 89,110 non-zero low bytes in 20 s, spread
  over at least channels 4 to 9 (up to 5,627 on one channel). The memory lock
  changes what the heap holds, and the reading of part 3 stands with more
  weight: unrouted receive channels return whatever the buffer was allocated
  with. Clearing the capture areas before start is a requirement for the
  owner process, not a nicety.

### Period and buffer sweep (02:05-02:07 UTC, unprivileged, 15 s each, no routes)

| Asked period / buffer | Granted | Wakes/s | Longest gap | Capture `avail` | Playback `delay` (lead) | Recoveries | Stray non-zero samples |
|---|---|---|---|---|---|---|---|
| 32 / 1024 | 32 / 1024 | 3,930 | 0.39 ms | 0-19 | 45-64 (64) | 0 | 1,406 |
| 64 / 2048 | 64 / 2048 | 2,447 | 0.70 ms | 0-34 | 94-128 (128) | 0 | 0 |
| 32 / 2048 | 32 / 2048 | 3,930 | 0.54 ms first second, 0.37 ms after | 0-26 | 46-64 (64) | 0 | 0 |
| 48 / 1024 | 64 / 1024 | 2,446 | 0.69 ms | 0-33 | 95-128 (128) | 0 | 1,406 |

- All four power-of-two requests were granted as asked. The bridge's own
  period of 48 was silently raised to 64, as the source said it would be.
- Period 32 halves the wake gap and the occupancy ranges; nothing recovered
  at either period in these short runs.
- The thread set did not change in any run. Each first `hw_params` took 250 ms.
- The stray samples appear at buffer 1024 and not at 2048. A 2048-frame
  buffer of sixteen 32-bit channels is 131,072 bytes, the size from which
  the C library hands out fresh zeroed pages instead of reused heap. That
  fits the unzeroed-buffer reading and means 2048 only looks clean by
  accident; the owner must still clear the buffer.
- Logs on the Pi: `/dev/shm/inferno-probe-20261009T0205{45}Z.log`, `…0206{03,21,40}Z.log`.

### Forced xrun as root under the lock (02:08:42 UTC, run by the operator)

`sudo -E run-probe.sh --seconds 15 --mlock --xrun-at 5`: both streams left
unserviced for 100 ms. Log `/dev/shm/inferno-probe-20261009T020842Z.log`.

- Playback: `avail_update` returned -32 with the PCM in `XRUN`; the plugin
  logged the underrun itself. `drop` + `prepare` took 8.4 ms, and the
  transmit thread was replaced (20707 became 20716, back at SCHED_FIFO 81
  once restarted). The longest wake gap in that second was 8.9 ms and about
  5,100 playback frames were not sent. Upstream's "long break" on xrun is,
  measured once, under 10 ms of blocking plus the missed audio.
- Capture did not report the overrun at all. After the hold `avail` read
  4,833 frames on a 1,024-frame buffer and no error came back, so the probe
  read four laps of overwritten ring as if it were continuous audio. The
  bridge treats an oversized `avail` as its own fault path; against this
  plugin an owner has to detect `avail > buffer` itself and resynchronise.
- Locked memory did not grow across the recovery (279.9 MB counted, 18.0 MB
  resident before and after).
- Per-second frame counts in this run moved by up to 17 around 48,000 where
  the unprivileged runs moved by 1. Not explained; the clock overlay being
  steered is the first thing to look at, with Statime at `info`.

### Discovery from the Mac: not working yet (02:10-02:12 UTC)

The operator reported the device missing from Dante Controller. Checked with
a 15-minute unprivileged probe left running (started 02:10:56 UTC):

- The ports are bound on `eth0` (4440, 4455, 8700, 8800) and 5353 is shared
  with `avahi-daemon`, which is active on the Pi.
- Queried on the Pi's own `eth0`, the plugin answers for `_netaudio-arc`,
  `_netaudio-cmc` and `_netaudio-chan` with its name.
- From the Mac (`dns-sd -B`), the 32 `_netaudio-chan` records for
  `USB-16x16-Inferno` appear, but the device-level `_netaudio-arc` and
  `_netaudio-cmc` records do not, in 4 to 9 s browses, while the Ferrofish
  and the D2USB appear at once. Cause not found.
- The device name was changed from `USB 16x16 Inferno` to `USB-16x16-Inferno`
  in `config/asound-inferno.conf` during this (Dante names take letters,
  digits and hyphens only). It was not established that the spaces mattered:
  the channel records were only browsed after the change. The plan's proposed
  network name needs the hyphens either way.
- Not yet tried: the same browse with `avahi-daemon` stopped, a packet capture
  of port 5353 on the Mac's audio interface, and Controller's own view.

### Controller and first routes (02:14-02:27 UTC)

- The device did appear in Dante Controller during the 15-minute run, with
  `avahi-daemon` left running. The `dns-sd` browse that missed its device
  records is therefore not a stand-in for Controller, and the discovery
  section above is closed as a non-problem for now.
- The operator routed in Controller. As logged by the plugin: Pi `RX 1-16`
  subscribed to Ferrofish `Output 49-64` (02:14:52-02:15:02 UTC, each
  "receiving data (unicast)"), and the Ferrofish requested the Pi's sixteen
  transmit channels as four 4-channel flows at 24 bit, 32 frames per packet.
  Which Ferrofish receive channels those feed is not in the Pi's log.
- No thread-set change across all of that routing (`thread_changes=0` over
  900 s), which is the first evidence on the blocking-pool question: route
  changes did not create threads.
- The plugin logged `received unknown opcode1 0x2204` repeatedly while
  Controller was open; nothing visibly followed from it.
- One playback xrun at 577 s of the unprivileged 900 s run (network threads
  at normal priority), recovered in 1.9 ms of `prepare`.
- With flows running the wake count rose from about 2,450 to about 17,500 a
  second, 11,400 of them spins, so the per-packet notifications are far
  denser than half a period once audio is flowing.
- **The pattern did not come back.** In the 900 s run channels 1 to 4 held
  non-zero audio that never locked and channels 5 to 16 were silent. A 25 s
  run with a dump showed what it is: channels 1 and 2 carry the same low
  noise (a few tens of 24-bit steps around zero, about -104 dBFS), not the
  full-scale pattern. So either the Pi's transmit is not reaching Ferrofish
  `Input 49-64`, which is what its matrix loops to `Output 49-64`, or the
  Ferrofish is not accepting it. Bit transparency is therefore untested.
- Persistence, seen in passing on that restart: the Ferrofish re-requested
  all four transmit flows within 2 s of the device returning; the Pi's own
  receive subscriptions came back one at a time, channel 1 after 5 s and
  channel 2 after 18 s, and no more within the 25 s.

### Bit transparency: PASS on this path (02:27:29-02:57:29 UTC)

One 1800 s unprivileged run, period 64, buffer 1024, `TX_SOURCE_BIT_DEPTH=24`,
24-bit flows at 32 frames per packet, path Pi `TX 1-16` -> Ferrofish ->
(MADI -> Metric Halo -> MADI) -> Ferrofish `Output 49-64` -> Pi `RX 1-16`.
Evidence:
`outputs/latency/dante-20261009T022729Z/` (`verify-summary.txt` is tracked;
`probe.log`, sha256 424f810a..., is gitignored and also kept on the Pi at
`~/usb-16x16-work/dante-mode/probe-long-20261009T022729Z.log`).

- The path was longer than the Ferrofish's own matrix loop. By the operator's
  account afterwards, the return also runs through the Metric Halo over MADI:
  what had been missing was MIOConsole3d routing its MADI receive channels
  back out, together with Ferrofish routing changes and some housekeeping on
  other devices in Controller. The exact routing was not recorded. The result
  below therefore covers Inferno transmit and receive plus the Ferrofish and
  the Metric Halo MADI loop, all bit-exact.
- Nothing matched for the first 570 s. After those changes all sixteen
  channels locked within half a millisecond of each
  other at 02:36:59 UTC, each on its own number (no channel arrived on
  another's).
- From lock to the end, 58.5 million samples matched on every channel,
  1,218.8 s of the 1,230 s. The other 11.4 s are two holes the probe made
  itself (below). Outside them there was not one mismatch: the mismatch
  counter stood still for 812 s and then for 381 s, about 936 million
  samples across the sixteen channels, every one equal to the sample sent.
- Both full-scale codes, 0x7FFFFF and 0x800000, came back intact at least
  three times on every channel. No returned sample had a non-zero low byte.
- So with the dither off, transmit and receive are bit-exact at 24 bits
  through this path, full scale included. This is one run on one path at one
  period; it says nothing about the default `TX_SOURCE_BIT_DEPTH=32`, which
  was not run and by the source would fail.
- No thread-set change in 1800 s, including across the operator's routing.
- Rate against `CLOCK_MONOTONIC_RAW` over the whole run: 47,999.37 frames/s,
  13 ppm under nominal. A steady offset like that is what a clock following
  the network would show, and is the first indication that Statime is
  steering; it is not a lock measurement.

### The cost of an xrun with audio flowing: 5.7 s

The same run had two playback xruns (at 591 s and 1,410 s; probe and network
threads all at normal priority). `prepare` took 15.4 ms and 6.6 ms, but the
returned audio was silent for 5.66 s and 5.74 s on every channel before the
pattern locked again, the second time in two steps (8 channels, then 16).
`prepare` tears down the transmitter, the flows go with it, and the Ferrofish
has to ask for them again. This is upstream's "several seconds of sound are
lost", measured. For this project it is the most important number so far: any
design in which the bridge's recovery path re-prepares the Inferno PCM turns
one RECOVER into a six-second dropout. The endpoint owner must never
re-prepare in steady state; a late USB side has to be absorbed by feeding
silence, not by restarting the network side.

### Stage 2 gates after the first night

| Gate | Status |
|---|---|
| ALSA contract | Works with the bridge's call set at periods 32 and 64, buffers 1024 and 2048. Three differences the owner must handle: the poll descriptor needs `snd_pcm_poll_descriptors_revents`; capture overruns are not reported; unrouted or freshly allocated capture buffers are not silence. Period 48 is not available. |
| Transmit bit transparency | Passed with `TX_SOURCE_BIT_DEPTH=24`, full scale included (one 30-minute run). |
| Thread creation | Threads are created in `hw_params` and replaced at every `prepare`; none appeared while running or on route changes. Separate owner process, as decided. |
| Not yet measured | Latency (the probe does not measure it), PTP lock quality, a run as root long enough to count xruns with the network threads at real-time priority, Controller restart and reconnect persistence. |

### alsaloop prototype wrapper (written 2026-10-09 ~03:40 UTC, staged, not run)

`run-alsaloop-prototype.sh [SECONDS] [LATENCY_USEC]` connects the USB gadget to
the Inferno device in both directions through one `alsaloop` process (two jobs
in one config, because Inferno allows one process per device), with
`config/asound-inferno-loop.conf` adding the system ALSA configuration to the
probe's device. It is for a first end-to-end answer from the Mac and an upper
bound on latency, not a candidate: `alsaloop` resamples to follow the two
clocks (`-S samplerate -A sincfastest`, as the 2026-08-31 AES67 prototype did,
so not bit transparent), adds its own buffering, and re-prepares on xrun,
which costs about six seconds each time. Defaults: 600 s, 20 ms inside
`alsaloop` per direction, period 64, buffer 1024, Inferno latencies at 10 ms.

It must be run as root on the Pi with Statime running and the AES67 service
stopped, and refuses otherwise; it also refuses beside a running probe or
another `alsaloop`. It reads the gadget's pitch controls before and after and
does not write them, logs to tmpfs, and hands the state directory back to the
invoking user. Checked so far: shell syntax, the refusal path, that both
device names resolve under its ALSA config, and that the Pi's `alsaloop` is
built with the sample-rate converter. Staged hashes:

```
d86dab3b3a4035f847714be4a6deb51b325bffa38a65a808da4a0bc3955a392a  run-alsaloop-prototype.sh
2f0e3941c5ac8822a034901f8c492c3f0e6529cebb7963f27e2b39bf2f61dd5a  config/asound-inferno-loop.conf
```

### Prototype, first run and the fix (03:40-03:44 UTC)

- First run as root (03:40:31 UTC, by the operator): the Mac's output reached
  the Pi and the Ferrofish took the transmit flows, but the Dante -> USB
  direction stopped (gadget playback in `XRUN` at 960 frames) and `alsaloop`
  spun a core at SCHED_RR 99. Stopped by the operator. The job file's `-E` and
  `-B` were rejected as invalid options, so the sizes were `alsaloop`'s own
  (gadget period 320, buffer 3840). The two `Inferno main` threads inherited
  RR 99 from `alsaloop`, as the source read predicted for a real-time opener.
- Isolated unprivileged, 8 to 14 s each, the Mac streaming throughout:
  Dante -> USB alone ran (gadget playback advancing, `alsaloop` at 10 % CPU);
  USB -> Dante alone ran; both jobs on one `alsaloop` thread reproduced the
  spin and the stuck return exactly; both jobs with `-T -1` (a thread each)
  ran, both gadget streams advancing at 48 kHz with about 950 frames queued
  toward the Mac, about 10 % CPU per thread.
- So the fault is `alsaloop` serving two loops on the same Inferno device from
  one thread, not the return direction. Cause inside `alsaloop` not traced.
- Wrapper changed: `-T -1` on both jobs; period and buffer left to `alsaloop`
  unless `PERIOD` / `BUFFER` are set, and then passed by their long names.
  Staged: sha256 86eaa0246ae45f822f0dd8b82c92fa56d089d44724daad6dc2d62619aa679219
  (supersedes d86dab3b above). Not yet run as root in this form, and no audio has
  been confirmed at the Mac.

### First USB-to-Dante round trip: 73.271 ms at 224 frames (03:44-03:47 UTC)

The fixed wrapper, run as root by the operator from 03:44:35 UTC (log
`/dev/shm/dante-alsaloop-20261009T034435Z.log` on the Pi), Statime as before,
routes as left from the bit-transparency run (Pi -> Ferrofish -> MADI ->
Metric Halo -> MADI -> Ferrofish -> Pi).

- RTL Utility, `USB 16x16` in and out, channel 1 to channel 1, 48 kHz, buffer
  224 frames: **3,517 samples, 73.271 ms**, of which 696 are CoreAudio's
  reported latency; return level -21.6 dB. Screenshot:
  `outputs/latency/dante-20261009T034435Z/rtl-utility-224f.png`. One reading.
  224 was the smallest buffer the operator could run; what happened below it
  was not recorded.
- This is the first audio from the Mac through the USB gadget, out over native
  Dante, around the loop and back. It answers the usability question: the Pi
  is routable in Dante Controller as an ordinary device and the Mac's USB
  interface passes audio through it.
- At 03:47 UTC, three minutes in: both gadget streams running at 48 kHz, no
  xrun in the log, `alsaloop` at 20 % CPU per thread at SCHED_RR 99 with no
  spin, about 960 frames queued toward the Mac.
- The figure is the prototype's configured buffering, not a floor: `alsaloop`
  holds 20 ms in each direction (1,920 samples) and Inferno's receive latency
  is at its 10 ms default (480). Those two alone are 2,400 of the 3,517; the
  Mac's 696, the Ferrofish's receive latency for the Pi's flows (not read)
  and the MADI loop make up the rest. Nothing here was measured stage by
  stage.
- Not comparable with the AES67 record (18.563 ms): different buffer size
  (224 against 32), resampling in the path, no fresh-anchor or noise-probe
  discipline, one reading.

### alsaloop at 5 ms: 35.354 ms at 32 frames (03:49-03:52 UTC)

Same prototype with `alsaloop` at 5,000 us per direction (run from 03:49:38
UTC, log `/dev/shm/dante-alsaloop-20261009T034938Z.log`); Inferno latencies
still 10 ms; routes unchanged.

- RTL Utility at buffer 32, channel 1 to 1: the operator saw the figure rise
  over consecutive readings and settle. The two recorded: 1,687 samples
  (35.146 ms) and 1,697 samples (**35.354 ms**), CoreAudio reporting 312,
  return level -21.6 dB. Screenshots in
  `outputs/latency/dante-20261009T034938Z/`.
- Below 224 frames on the 20 ms run RTL had answered "Couldn't reliably detect
  test signal" (screenshot at 192 in the 034435Z directory). At 5 ms it
  measures down to 32, so that was RTL's detection reach against a 73 ms round
  trip, not a fault in the path.
- No xrun in the log two minutes in; both gadget streams running; `alsaloop`
  10-20 % CPU per thread. The queue toward the Mac read 167 frames four
  seconds in and 235 two minutes in, which is the rise the operator saw:
  `alsaloop` settling its own fill, about 70 frames.
- The two runs agree on what is left when the configured terms are taken out:

  | | 20 ms run, buffer 224 | 5 ms run, buffer 32 |
  |---|---|---|
  | RTL total | 3,517 | 1,697 |
  | `alsaloop`, both directions (configured) | 1,920 | 480 |
  | Inferno receive latency (configured) | 480 | 480 |
  | CoreAudio reported | 696 | 312 |
  | Remainder | 421 | 425 |

  The remainder, about 8.8 ms, is everything not configured here: the
  Ferrofish's receive latency for the Pi's flows, the MADI loop through the
  Metric Halo, Inferno's transmit path and `alsaloop`'s settling. That it
  comes out the same from two different settings supports the bookkeeping;
  none of it was measured stage by stage.
- Against the AES67 record at the same buffer (18.563 ms, 891 samples) the
  prototype is 806 samples longer, with 960 of its own configured buffering
  still in it. Not a like-for-like comparison: resampling in the path, no
  fresh anchor, no noise probe, two readings.
- The wrapper gained a third argument, `INFERNO_LATENCY_NS`, which sets both
  Inferno latencies for one run through a copy of the config on tmpfs
  (staged, sha256 52b2cad4242d916f2f165b283ae02dc22da77114c13a8c0b06175e1480675aa9,
  not yet run with it).

### Inferno latencies at 2 ms: 19.708 ms at 32 frames (03:54-03:56 UTC)

Same prototype, `alsaloop` still 5,000 us per direction, both Inferno
latencies set to 2,000,000 ns through the wrapper's third argument (run from
03:53:59 UTC, log `/dev/shm/dante-alsaloop-20261009T035359Z.log`).

- RTL Utility at buffer 32, channel 1 to 1: by the operator's account the
  readings first rose past 27 ms and then came down and settled at **946
  samples, 19.708 ms** (CoreAudio 312, return level -21.6 dB). Screenshot
  `outputs/latency/dante-20261009T035359Z/rtl-utility-32f-946.png`. One
  recorded reading.
- That is 751 samples under the 10 ms run, close to twice the 384 that one
  direction's 8 ms is worth. So the setting moved both ends: the Pi's own
  receive latency and, through what the Pi advertises, the Ferrofish's
  receive latency for the Pi's flows. A reading above 27 ms followed by this
  one fits the Ferrofish taking the new figure a little after the Pi did;
  that order of events was not observed, only the readings.
- It also means the table above mis-assigned its parts: with both ends at 10
  ms there were 960 samples of Dante latency in those runs, not 480, so
  `alsaloop` holds less than its nominal 240 per direction and the
  "remainder" was not what it was labelled. The totals stand; the split does
  not.
- Two minutes in: no xrun and no transmit-lag line in the log, both gadget
  streams running, about 257 frames queued toward the Mac and 0 to 36 on the
  capture side, `alsaloop` 10-20 % CPU per thread.
- 946 is 55 samples (1.1 ms) above the AES67 record at the same buffer (891,
  18.563 ms), from a resampling prototype. It is not an operating point and
  not yet a comparison: one reading, no noise probe, no fresh anchor, no
  loaded impulse runs, no soak. Above all, integrity is unchecked at this
  setting. A packet that arrives later than 2 ms is dropped without a log
  line and RTL would not notice; only a continuous-signal check will show
  whether 2 ms holds on this network.

### Direction change, harness wrapper and a no-resampling mode (04:04-04:10 UTC)

- The operator's decision at about 04:05 UTC: the AES67 service is not being
  started again; development continues on the Dante path unless a hard block
  appears. `usb16x16-aes67.service` has been stopped since 03:40 UTC and the
  Ferrofish and Metric Halo routing now serves the Dante loop.
- The 2 ms run ended on its 600 s timer at 04:03:59 UTC with no xrun or
  transmit-lag line in its whole log and the pitch controls untouched.
- `measure-candidate.sh FRAMES IMPULSES [LABEL]` is the Dante counterpart of
  `work/aes67-candidate/measure-under-service.sh`: the same harness and the
  same signal gating, with Pi-side checks for the Dante stack (AES67 stopped,
  Statime running, an endpoint process running) and the endpoint log read
  before and after for xrun, lag and error lines. `measure-candidate.sh noise
  FRAMES [LABEL]` is the hole probe as the handoff defines it (out 1, in 2,
  0.1 load on the other channels, the capture analysed by `zeros.py`).
  Checked: syntax, and that it refuses with no endpoint running. Not yet run
  against a live endpoint.
- `SYNC=pitch` on the prototype wrapper takes the resampler out: `alsaloop`
  follows the clocks by steering the gadget's `Capture Pitch` and `Playback
  Pitch` controls (`-S captshift` going out, `-S playshift` coming back), the
  same lever the bridge's servo uses, and the wrapper sets both back to
  1000000 on exit. Tried unprivileged for 40 s at 5 ms with the 10 ms Inferno
  default: `alsaloop` reported "shared buffer" (no converter in the path) and
  sync types CAPTRATESHIFT / PLAYRATESHIFT, both directions ran, the controls
  moved to 1000010 and were back at 1000000 afterwards. Forty seconds does
  not show that the steering converges, and bit transparency through it is
  unmeasured. Staged wrapper sha256
  0899dca88b276cee618a5dda4c6cdd4f3e0df87e28ec95f3d54229097f076111.

### No resampler, harness-measured: 705 samples at 32 frames, four runs (04:08-04:23 UTC)

Prototype started by the operator as root at 04:08:01 UTC:
`SYNC=pitch run-alsaloop-prototype.sh 1200 5000 2000000` (no converter,
`alsaloop` 5 ms per direction, both Inferno latencies 2 ms). Measured from the
Mac with `measure-candidate.sh`, label `dante-pitch`; RTL Utility closed.
Evidence: `outputs/latency/dante-pitch-*-20261009T04*`.

| Run (UTC) | Kind | Result | Spread | Discontinuities | Pi xrun / lag lines |
|---|---|---|---|---|---|
| 04:08:13 | noise probe, out 1 / in 2, 0.1 load, 32 frames | 0.0 % zeros, no zero run of 4 or more in 1,244,707 samples | | | 0 / 0 |
| 04:09:05 | 800 impulses, 0.1 load, 32 frames | 705 samples, 14.688 ms, all 800 | 0 | 0 in, 0 out | 0 / 0 |
| 04:12:51 | same | 705, all 800 | 0 | 0, 0 | 0 / 0 |
| 04:16:26 | same | 705, all 800 | 0 | 0, 0 | 0 / 0 |
| 04:20:02 | same | 705, all 800 | 0 | 0, 0 | 0 / 0 |

- 3,200 impulses on one sample across fifteen minutes of one process, with
  the pitch controls moving inside about +/-30 ppm (117 pitch updates logged)
  and the queue toward the Mac between 228 and 253 frames.
- The AES67 record's harness figure is 703 (bridge 947e8b4d; 725 and 746 on
  other starts). 705 is in that family. By the standing rule RTL at 32 reads
  the harness figure plus 188, which would be 893 samples, 18.604 ms; that is
  derived and was not read on this run.
- Against the resampling run's RTL reading (946) the pitch mode is about 53
  samples shorter by that derivation, which is the size a converter's filter
  delay in each direction would be; not separately measured.
- What this is: the standard four loaded 800-impulse runs and a clean noise
  probe, on one start of a prototype. What it is not: ACCEPTED. Missing are
  the ten-minute sixteen-channel soak, a fresh-anchor discipline for this
  transport (whether the level is a per-start draw here is unknown; all four
  runs share one start), an RTL reading, bit transparency through `alsaloop`
  in this mode, and any test of what happens when the Mac closes the device.
- Controller, during these runs: the operator saw `RX 4-12` of the Pi shown
  as "Unresolved, cannot find this channel on the network" a few minutes
  after the start; they turned green when he had Controller reload device
  information. So the subscriptions had resolved and Controller's view was
  stale; how long the resolution itself took is not known.
- The endpoint log's only errors in the run are the two start-time lines at
  open and the `unknown opcode1 0x2204` pairs that appear while Controller is
  talking to the device.

### Second start: RTL 884 samples and the sixteen-channel soak (04:30-04:44 UTC)

Prototype restarted by the operator at 04:29:59 UTC with the same settings
(`SYNC=pitch`, `alsaloop` 5 ms, Inferno 2 ms; a 1200 s run).

- RTL Utility at buffer 32, channel 1 to 1, the settled reading: **884
  samples, 18.417 ms** (CoreAudio 312, return level -21.6 dB). Screenshot
  `outputs/latency/dante-pitch-rtl-20261009/rtl-utility-32f-884.png`; no xrun
  or lag line on the Pi at 04:33:05 UTC. This is 7 samples under the AES67
  record's RTL reading at the same buffer (891, 18.563 ms).
- By the plus-188 rule the harness on this start would read 696, against 705
  measured on the previous start. The harness was not run on this start
  before the soak, so whether the level differs between starts by those 9
  samples, or RTL's settled reading sits that far from the rule on this
  transport, is open. It is the first sign that the level may be a per-start
  draw here too.
- Soak, `measure-candidate.sh soak 600 32 dante-pitch` from 04:33:10 UTC:
  600 s of 0.1 load on all sixteen channels at 32 frames. **PASS**: sixteen
  channels returned at peak 0.1000, longest zero run 1 sample on any channel
  (the criterion fails at 4), 0 input and 0 output discontinuities, and on
  the Pi no xrun and no lag line added, both gadget streams running before
  and after, pitch controls within about 26 ppm. Evidence
  `outputs/latency/dante-pitch-soak-600s-32f-20261009T043310Z.json` and its
  `-api` directory.
- With the four loaded 800-impulse runs of the previous start, the prototype
  has now met the measurement half of the repo's acceptance rule, split over
  two starts. It is still a prototype: `alsaloop` at SCHED_RR 99, started by
  hand as root with Statime in a terminal, nothing that survives a reboot or
  a closed DAW, bit transparency in this mode unmeasured.
- A plan for the slow subscription resolution and the stale Controller status
  is in `PLAN.md` as stage 3a.

### Still owed for stage 2

1. Done 2026-10-08, above.
2. Done 2026-10-09 01:38-01:43 UTC: both built on the Pi with
   `--release --locked -j2` on rustc 1.99.0, service stopped, first attempt,
   no source or lock changes (compiler warnings only). Hashes are in
   `SOURCES.lock`; the script is `build-candidate.sh`. Two jobs because the Pi
   has 990 MB of RAM; the one mid-build reading showed 518 MB available, the
   peak was not watched. The staging directory is
   945 MB and the crate cache 161 MB. Nothing was installed or run.
3. Part done (part 3): period 64 / buffer 1024 and the `--no-revents` spin.
   The root run with `--mlock` and the period / buffer sweep are done too.
   The forced xrun is done as well. Evidence
   of PTP lock needs Statime at `loglevel = "info"` for one start.
4. Bit transparency measured in both directions with `TX_SOURCE_BIT_DEPTH=24`,
   full scale included.
5. A thread trace across open, prepare, start, a route change, a forced xrun
   and close, to confirm the part 1 table and to settle the blocking-pool
   question.

## Source read for the owner design (2026-10-09 ~14:00-14:45 UTC, no audio run)

Written up in [OWNER_DESIGN.md](OWNER_DESIGN.md), which is the plan for the
process that replaces `alsaloop`. Statime and the prototype were down
throughout (Pi up 13 h 45 m, `usb16x16-aes67` inactive, nothing Dante
running), so everything in this section is a reading of source or a build
result. Nothing was run against the network.

Readings, with where they come from:

- alsa-lib 1.2.14 (`src/pcm/pcm_ioplug.c` 57-90, 752-765): an ioplug PCM
  enters `XRUN` only when the plugin's `pointer` callback returns a negative
  value. There is no stop-threshold comparison, and entering `XRUN` does not
  call the plugin's `stop`. This explains the unreported capture overrun of
  part 3 (the plugin's pointer never errors for capture) and means the 5.7 s
  is the cost of the `prepare` a recovery calls, not of the underrun.
- `alsa_pcm_inferno/src/lib.rs` 268-286: the plugin returns `-EPIPE` for a
  playback pointer behind the clock, except in the first 100,000 frames after
  start, where upstream already lets it run on unreported.
- `inferno_aoip/src/ring_buffer.rs` 97-99, 393-396 with `flows_tx.rs`
  154-173: the transmit thread reads the plugin's mmap buffer unconditionally.
  Frames the application has not written go out as the previous lap's audio
  (21.3 ms old at a 1024 buffer). Part 1's "sent as zeros" is corrected in
  place above.
- `flows_tx.rs` 147-201, 512-520: with send latency fixed at zero the thread
  reads up to one packet (32 frames as the Ferrofish asked) ahead of the
  clock, so that is the floor of any playback lead.
- `flows_rx.rs` 229-230, 314-315: received samples are written at their
  timestamp plus the receive latency.

What was made, none of it run:

- `probe/inferno-probe.c` gained `--free-run`: with `avail` above the buffer
  size it forwards the application pointer past the loss and prints
  `NETRESYNC` with a thread inventory, and it never prepares; an error from
  `avail_update` prints `FREERUN-FAILED` once. Compiled on the Pi with
  `gcc -O2 -Wall -Wextra`, no warnings. The previous binary and source are
  kept beside it as `inferno-probe-0ccef1e8` and `inferno-probe-fd0c6b0d.c`.
- `patches/0001-alsa-plugin-xrun-report-option.patch`: one config key,
  `XRUN_REPORT`, default unchanged; `"0"` makes the playback pointer skip the
  `-EPIPE` as the grace window does.
- `build-patched.sh` built it on the Pi at 14:42 UTC (25 s, rc 0, the same
  eight warnings as the stock crate) as a second artifact and put the pinned
  source and the stock product back; both re-hashed afterwards and equal to
  `SOURCES.lock`. `inferno/target/release` still holds ca99efd7, so the probe
  and prototype wrappers run the stock plugin unless told otherwise.
- `probe/run-probe.sh` takes `INFERNO_CONFIG` and `INFERNO_PLUGIN_DIR` for one
  run and prints the plugin's hash; `config/asound-inferno-freerun.conf` is
  the probe's device with `XRUN_REPORT "0"`.

Staged on the Pi under `~/usb-16x16-work/dante-mode/` and matching the repo:

```
abeda2c0  probe/inferno-probe   (binary, Pi only)
06272cc8  probe/inferno-probe.c
a82bdbf1  probe/run-probe.sh
225b2f17  config/asound-inferno-freerun.conf
04c6832e  patches/0001-alsa-plugin-xrun-report-option.patch
b5cdb93e  build-patched.sh
ca99efd7  plugins/stock/libasound_module_pcm_inferno.so        (the pinned build)
55dee5d8  plugins/xrun-option/libasound_module_pcm_inferno.so  (pinned tree + 0001; 6,941,608 bytes)
```

Owed next, in OWNER_DESIGN.md's order, each needing Statime up (root, the
operator) and nothing else: step 1, the free-run hold inside the grace window
on the stock plugin; step 2, the same hold at steady state on the patched
plugin with the saved loop routes, read against the 5.7 s; step 3, the
stale-audio check, which needs one more probe option.

## Owner design steps 1 and 2: the free-run resync works (2026-10-09 17:58-18:02 UTC)

Statime started by the operator at 17:57 UTC with the first-run config; probe
unprivileged over ssh, period 64, buffer 1024, all threads at normal priority;
`usb16x16-aes67` inactive; routes as left on 2026-10-09 (the Ferrofish and
Metric Halo loop). Evidence `outputs/latency/dante-20261009T175928Z/`
(`step2-freerun-summary.txt` tracked; the two probe logs gitignored).

| | Step 1: stock plugin ca99efd7 | Step 2: patched plugin 55dee5d8, `XRUN_REPORT "0"` |
|---|---|---|
| Run | 10 s, 100 ms hold at 1 s (inside upstream's grace window) | 180 s, 100 ms hold at 120 s (steady state, flows up) |
| Playback after the hold | `avail` 5,709 on 1,024; forward 4,685; state `RUNNING` | `avail` 5,706; forward 4,682; state `RUNNING` |
| Capture after the hold | `avail` 4,807; forward 4,743 | `avail` 4,804; forward 4,740 |
| `prepare` / recoveries | none / 0 | none / 0 |
| Thread ids | unchanged (`flows RX` 94067, `flows TX` 94069) | unchanged (94134, 94136), `thread_changes=0` |
| Lead afterwards | playback delay 95-128 from the next second | same |

- Step 2 against the 5.7 s: all sixteen channels were locked on the pattern
  at every one-second report through and after the hold (119.0, 120.1, 121.0
  and on). The mismatch lines show two discontinuities on all sixteen
  channels, at 120.3607 s and 120.3735 s, 7.7 ms and 20.4 ms after the hold
  ended at 120.3531 s; the pattern needs 16 matching samples to count as
  locked, so the stream was whole again about 21 ms after the hold. So the cost of a 100 ms stall was the stall,
  where the stock recovery cost 5.66 s and 5.74 s. One hold, one run.
- The clock moved 4 to 5 frames between the probe reading the deficit and the
  forward landing (the plugin logged `buffered -4` and `-5` straight after).
  The owner's resync forwards by the deficit plus a margin, or to
  clock + lead in one step.
- Every channel shows those two lock losses and no zero run at the hold. A hole of
  zeros would have counted as a zero run; old pattern laps would not. That is
  what the stale-audio reading predicts, but the capture side had skipped
  most of the window, so it is an indication only. Step 3 is the test.
- Channels 3 and 11 carry 1,478 and 2,572 non-zero low bytes, all before
  their subscriptions resolved: the unzeroed capture buffer again.
- For PLAN 3a, one cold start with the saved sixteen subscriptions, read as
  the time each channel first locked through the loop: two channels at 16.5
  s, then 16.9, 18.6, 31.8, 44.9 and the last group at 55.1 s. That is the
  loop's figure, not the subscription's alone, and `RUST_LOG` was `warn`.
- Step 1's first seconds show the cost of the flows arriving: wakes rose from
  2,450 to 13,000 a second at 6 s, as on 2026-10-09.

## Owner design step 3: unwritten frames go out as the old lap; zero-behind fixes it (2026-10-09 18:04-18:08 UTC)

Same conditions as steps 1 and 2, stock plugin ca99efd7, two 100 s runs. The
probe gained `--hold-forward` (during the hold the capture is still read and
the playback pointer still advances, but nothing is written: 4,800 frames
committed unwritten) and `--zero-behind` (on every wake the playback buffer
is cleared up to 256 frames behind the clock). Probe binary 381f348c, source
2e0bcfb1, staged; the previous binary kept as `inferno-probe-abeda2c0`.
Evidence `outputs/latency/dante-20261009T175928Z/step3-stale-audio-summary.txt`.

| 100 ms unwritten at 85 s | without `--zero-behind` | with `--zero-behind` |
|---|---|---|
| Zero samples returned across the hold (16 channels) | 0 | 76,784, which is 16 x 4,799 |
| Lock losses per channel | 6 | 1 |
| Zero runs per channel | 0 | 1 |
| Mismatch events | on all channels every 21.333 ms (1,024 frames), the same wrong sample each time | one, the first zero |
| Rest of the run | locked, no further mismatch | locked, no further mismatch |

- Reading 4 of the design is confirmed by measurement: frames the application
  does not write are transmitted as the previous lap of the buffer, lap after
  lap, at full level. Through an `alsaloop` or any owner that stalls with
  audio in its buffer this is a 21 ms repeat, not a dropout.
- With the buffer cleared behind the clock the same hold returns exactly the
  hold's length of zeros and nothing else. The 256-frame guard did not touch
  live audio: 4,799,937 frames were cleared in 100 s and the pattern matched
  on every channel outside the hold.
- Neither run recovered, resynchronised or changed a thread; the pointer was
  never behind, so the plugin had nothing to report.

## Owner design step 4, first build: the network half runs (2026-10-09 18:11 UTC, unprivileged trial)

`owner/main.cpp` is the owner's network half (`--no-usb`): memory lock, its
telemetry thread, the Inferno PCMs opened without a second prepare, both
buffers cleared, the lead written as silence, one `start` each, then a 1 ms
loop that discards the capture, clears the playback ring behind the clock
less the guard, resynchronises by forwarding (deficit plus 16 frames) and
tops the lead up. It exits rather than prepare if the PCM ever reports an
error. `run-owner.sh` wraps it (refusals as the prototype's, log on tmpfs,
`plugins/xrun-option`, `config/asound-inferno-owner.conf`: the probe's device
identity, both latencies 2 ms, `XRUN_REPORT "0"`, `DISABLE_POLLFD "1"`).
Built on the Pi with `g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror`,
no warnings. Staged and matching the repo:

```
7eb9a584  owner/usb16x16-dante-owner  (binary, Pi only)
f914c8d9  owner/main.cpp
2ca9730d  run-owner.sh
924cfa99  config/asound-inferno-owner.conf
```

One 30 s run, `TRIAL=1` (no memory lock, every thread at normal priority), so
it shows that the program works and nothing about stability. Log
`/dev/shm/dante-owner-20261009T181106Z.log` on the Pi.

- Start: `hw_params` 250 ms for capture as before; four Inferno threads after
  the opens and no others created afterwards; both PCMs `RUNNING`.
- Steady state: 1,000 wakes a second, 48,019 frames a second each way, the
  depth before each top-up 78 to 82 (the lead of 128 less one millisecond),
  the ring index never disagreeing with the owner's own count
  (`offset_mismatches=0`), no PCM error.
- At 26.4 s the whole process lost the CPU for 7.2 ms (normal priority). The
  plugin logged the pointer 21, 171 and 217 frames behind and its transmit
  thread `tx lag of 218-275 samples`; the owner forwarded three times (409
  frames in all), both PCMs stayed `RUNNING`, the thread ids did not change,
  and it carried on. That is an unplanned instance of step 2's result, in the
  owner itself.
- The Ferrofish asked for its flows at 16.9 s (`add flow request for already
  existing flow`), as on every start.

Not done, and what step 4's check asks for: an hour as root with the memory
lock and real-time priority, routes up, zero resyncs, no thread change.

## Owner design step 4: PASSED, one hour as root (2026-10-09 19:09-20:09 UTC)

`sudo run-owner.sh 3600` by the operator (the network half alone; owner
7eb9a584, plugin 55dee5d8, memory lock, loop thread SCHED_FIFO 79, Statime as
started at 17:57 UTC). Evidence `outputs/latency/dante-owner-nousb-20261009T190925Z/`
(`summary.txt` tracked, the log gitignored).

- 3,600.05 s, exit 0. 172,799,896 frames out and 172,799,768 in, 48,000.0 a
  second. **Zero resyncs in either direction, zero PCM errors**, the ring
  index never off the owner's count, both PCMs `RUNNING` at the end.
- No `tx lag`, `XRUN`, dropout or clock line from the plugin in the hour. Its
  only lines are the Ferrofish's flow requests at 24 s and twelve
  `unknown opcode` packets in the first two minutes (Controller).
- Depth found on each wake 79 to 82 after the first ten seconds (50 to 112 in
  them); the longest gap between wakes 1.57 ms in the first ten seconds and
  1.00 to 1.02 ms afterwards.
- Threads: the two `Inferno main` at normal priority, `flows RX` FIFO 80,
  `flows TX` FIFO 81, as designed. **One finding:** `flows TX` was not there
  when the opens returned. It is absent from the `after-open` and `running`
  inventories and present at the end with a thread id six above the others,
  so under the memory lock the plugin's runtime made it after the loop had
  started. Harmless in this run (no gadget), but it is a thread created late,
  which rule 3 exists to prevent. The owner now waits for both flow threads
  by name before it starts (`NETTHREADS`), and refuses to run without them.
- Not observed by me: what Controller showed during the hour.

## Owner design step 5, first trials of the USB half (2026-10-09 20:24-20:26 UTC, unprivileged)

`owner/main.cpp` with the USB half (the three departures from the design are
listed at the top of OWNER_DESIGN.md), built on the Pi, two `TRIAL=1` runs of
40 s and 30 s with the Mac streaming both ways. No memory lock and no
real-time priority, so these show that it works, not how well. Text of both
logs: `outputs/latency/dante-owner-usb-trials-20261009/trials.txt`.

Staged and matching the repo:

```
48d51783  owner/usb16x16-dante-owner  (binary, Pi only; 7eb9a584 kept beside it)
6d19e7ff  owner/main.cpp
e3d560b3  owner/servo.hpp
12074a7b  run-owner.sh
761b46fa  build-patched.sh
```

- The gadget opened at period 48, buffer 480, and both directions linked
  within 0.3 s of the start. 47,990 to 48,030 frames a second each way, no
  gadget capture fault, no detach, pitch controls back at 1000000 after exit.
- Out: the prime found the silent lead at 91 and landed a 48-frame block at
  128; the one-second mean read 125.9 at 5 s.
- The two clocks: the outgoing depth fell about 0.6 frames a second and the
  return queue rose, so the Mac's USB clock runs roughly 10 ppm slow against
  Dante here, and both servos were walking toward it as the model says they
  would (pitch +9 and +6 after 30 s, integrals still under 2 ppm). Thirty
  seconds is a third of the loop's time constant; convergence is not shown.
- First run: at 24.9 s the unprivileged process lost the CPU, the plugin
  logged the pointer 109 frames behind, one `NETRESYNC`, the gadget queue ran
  dry (one playback fault, primed again) and the outgoing direction was
  primed again from the block that followed the stall. That prime came out 37
  frames deep (mean 165 against 128). Read as: after a stall the gadget
  delivers its backlog over more than one wake, so a prime made on the first
  block is deeper by what arrives next. Changed: a direction that has to be
  primed again discards the block in hand, and a prime is only made on an
  ordinary block (at most one and a half periods). Not re-tested, because the
  second run had no stall.
- **Open, second run:** the return queue sat at 181 after each write for the
  first 15 s, 37 above its target of 144, and between 15 s and 20 s came down
  to 146 in a step the servo cannot have made (19 ppm for 15 s is 14 frames).
  No fault, no overflow, no reprime was counted. So the return prime does not
  land where it is set, and something then moved the queue by about 35
  frames. Five-second lines cannot say what; the next run logs every second.
  Until this is understood the return direction's start depth is a draw, not
  a setting, which is the thing the design set out to remove.

## Owner with the USB half, first run as root: RTL 14.646 ms at 32 frames (2026-10-09 20:32-20:42 UTC)

`sudo run-owner.sh 600 --log-every 1` by the operator: owner 48d51783, plugin
55dee5d8, memory lock, loop SCHED_FIFO 79, `--tx-lead 128`, `--rx-queue 144`,
Inferno latencies 2 ms, gadget period 48 / buffer 480, servos from zero.
Statime as started at 17:57 UTC; routes as left (the Ferrofish and Metric Halo
loop). The Mac held both streams for the whole run. Evidence
`outputs/latency/dante-owner-usb-20261009T203206Z/` (`summary.txt` and the
per-second table `depths.txt` tracked; the log gitignored).

- **RTL Utility at buffer 32, by the operator: 14.646 ms** (703 samples), and
  just under 14 ms at 16. Audio came back through the loop. One reading each,
  no screenshot, taken at an unrecorded moment of a run whose two depths were
  still moving (below), with no noise probe and no harness run on this start.
  For scale: the `alsaloop` prototype read 884 samples at 32 and the AES67
  record is 891 (18.563 ms), so this is about 180 samples, 3.8 ms, under
  both. It is a first reading, not an operating point.
- The run: 600.01 s, exit 0. One link in each direction at 0.3 s and none
  after; no gadget fault, no reprime, no detach, no overflow or discard; zero
  `NETRESYNC`, zero PCM errors, no `tx lag` or `XRUN` line from the plugin; no
  thread change; pitch controls back at 1000000 afterwards. The longest gap
  between wakes in ten minutes was 1.031 ms.
- The servos did what the model said. The Mac's USB clock is 15.3 ppm slow
  against Dante on this start; both integrals reached it (out -15.28, back
  +15.50, equal and opposite as they should be). From a cold start the
  outgoing mean fell from 128 to 104.8 at 90 s and was back within 2 of 128
  from 390 s; the lowest depth found on any wake was 56, above the 32-frame
  packet floor, so nothing was primed again. The return mean rose from 144 to
  165 and settled at 141 to 142. So for the first six minutes of a cold start
  the round trip is not at its set depth, by up to about 20 frames each way
  with opposite signs. `--seed-ppm -15` would start both where they ended.
- **The open question from the trials, now with one-second lines.** The
  return queue as found before each write sits at 93 to 94 once settled, and
  about every 16 s (14 s while the pitch was still moving) it reads 37 to 38
  frames higher for one to two seconds and then returns: forty times in the
  run, never with a frame dropped or a fault. The wake cadence did not move
  with it (no gap over 1.031 ms), and the outgoing depth found on the same
  wakes is steady to a frame. So either the host's pulls are periodically 0.8
  ms late against its own sends for a second, or the gadget's playback
  pointer is reported late for a second; the second is a reading artefact,
  the first is 0.8 ms of real delay coming and going. The trial's "15 s at
  181" was a long instance of the same thing. Each episode also puts a
  +35-frame error into the return servo for a second (Playback Pitch jumps
  from +15 to about +30), which is small (0.7 frames) but not clean.
  What decides it: 800 harness impulses span about thirteen episodes, and a
  real delay change shows as impulses 37 or 38 samples apart, an artefact as
  spread 0.

## The owner's battery on one start: 516 samples at 32 frames, spread 0, soak PASS (2026-10-09 21:13-21:39 UTC)

Owner started by the operator as root at 21:13:00 UTC:
`run-owner.sh 3600 --log-every 1 --seed-ppm -15` (owner 48d51783, plugin
55dee5d8, `--tx-lead 128`, `--rx-queue 144`, Inferno latencies 2 ms, gadget
period 48 / buffer 480). RTL Utility closed. Measured from the Mac with
`measure-candidate.sh`, label `dante-owner`, 32 CoreAudio frames throughout.
Evidence `outputs/latency/dante-owner-*-20261009T21*`.

| Run (UTC) | Kind | Result | Spread | Discontinuities | Pi xrun / lag / error lines |
|---|---|---|---|---|---|
| 21:13:16 | noise probe, out 1 / in 2, 0.1 load | 0.0 % zeros, no zero run of 4 or more in 1,244,829 samples | | | 0 / 0 / 0 |
| 21:13:57 | 800 impulses, 0.1 load | 516 samples, 10.750 ms, all 800 | 0 | 0 in, 0 out | 0 / 0 / 0 |
| 21:17:46 | same | 516, all 800 | 0 | 0, 0 | 0 / 0 / 0 |
| 21:21:21 | same | 516, all 800 | 0 | 0, 0 | 0 / 0 / 0 |
| 21:24:56 | same | 516, all 800 | 0 | 0, 0 | 0 / 0 / 0 |
| 21:28:32 | 600 s soak, 0.1 on all sixteen | PASS: sixteen channels at peak 0.1000, longest zero run 1 | | 0, 0 | 0 / 0 / 0 |

- 3,200 impulses on one sample over fifteen minutes, then ten minutes of
  sixteen-channel load with no hole, on one start of one process. That is the
  repo's measurement rule for an operating point (four loaded 800-impulse runs
  and the soak, after a clean noise probe), met on a single start.
- **516 against 705 for the `alsaloop` prototype and 703 for the AES67
  record: 187 to 189 samples, 3.9 ms, shorter.** By the plus-188 rule RTL at
  32 would read 704, 14.667 ms; the operator's reading on the previous start
  was 703 (14.646 ms), so the rule holds here to a sample, where the
  prototype's 884 against 705 had not fitted it.
- The return-queue question is answered: 3,200 impulses span about fifty of
  the sixteen-second episodes and none is displaced. The 37-frame reading is
  the gadget's playback pointer as reported, not delay. It still disturbs the
  return servo for a second each time (the pitch control read 1000029 once
  against 1000014 to 1000016 otherwise) and is worth removing from the
  servo's input, but it is not in the audio.
- With `--seed-ppm -15` the pitch controls read 1000015 / 1000015 from the
  first wrapper read, sixteen seconds in, and stayed within 1 of that.
- Not yet read: the owner's own log for this start (it runs until 22:13 UTC
  and is left alone until then), including what the harness's readiness
  probes, which open and close the device, did to the two links.
- What it is not: ACCEPTED. Missing are RTL on this same start, the three
  starts of owed item 1, bit transparency through the owner, the open/close
  and restart checks of step 5, and the hour of extended qualification. The
  owner is hand-started as root with Statime in a terminal and nothing
  survives a reboot.

## The same start, read whole: RTL 704, and an hour with no event (2026-10-09 21:13-22:13 UTC)

The owner run of the battery above, read after it ended on its timer.
Evidence `outputs/latency/dante-owner-usb-20261009T211300Z/` (`summary.txt`,
`stats.txt` tracked; the log gitignored).

- **RTL Utility at buffer 32, by the operator, after the battery on this
  start: 14.667 ms, 704 samples.** That is the harness's 516 plus 188 to the
  sample. Harness and RTL are now on one start.
- The hour: 3,600.02 s, exit 0, 172.8 million frames each way. One link per
  direction at 0.3 s and no other link event; no gadget fault, no reprime, no
  detach, no overflow, no discard; zero `NETRESYNC`, zero PCM errors; no
  `tx lag` or `XRUN` line from the plugin; no thread change; pitch controls at
  1000000 afterwards.
- Depths over the hour, seeded at -15 ppm: outgoing mean 126.6 to 129.3
  (128.04 overall), found between 73 and 82 before each write; return mean
  median 142.3. Capture Pitch stayed within 14 to 16 ppm. The longest gap
  between wakes was 1.060 ms; none over 1.1 ms.
- The return queue's reading artefact occurred in 162 of 3,598 seconds (mean
  above 160, found up to 180) and pushed Playback Pitch as far as +33 against
  a median of +15.
- **The device being opened and closed on the Mac does not reach the Pi.**
  Fifteen harness readiness probes, four impulse runs, the soak, RTL Utility
  and the operator quitting and reopening RTL twice produced no link event at
  all: the Mac kept both USB streams running throughout. So step 5's
  open/close check has not exercised the owner's idle, prime or fault paths,
  and will not by those means. What will: unplugging the USB cable, Mac sleep,
  `sudo killall coreaudiod` on the Mac, and a restart of `usb-16x16.service`.
- About twenty-five of the sixty minutes carried harness signal; the rest was
  whatever the Mac sent idle. It is an hour without an event, not the
  sixteen-channel loaded hour the plan's extended qualification asks for.

## The return queue's reading: a stale pointer, fixed (2026-10-09 22:19-22:29 UTC, unprivileged trials)

Two `TRIAL=1` runs with the Mac idle (its streams running, carrying silence).
Text: `outputs/latency/dante-owner-usb-trials-20261009/trials-servo-input.txt`.

- First a filter was tried (`DepthFilter` in `owner/servo.hpp`: the mean of
  the middle half of each second's readings, and a figure that steps more
  than 16 frames held back for at most five seconds). On a 330 s run it held
  back 159 seconds, the queue read above 160 in 110 of them, and Playback
  Pitch still ranged over 10 to 31. On this start the high reading lasted for
  long stretches, so after five seconds the servo would have believed it and
  moved the real queue by 37 frames. A filter does not fix a reading that is
  wrong for that long.
- The cause: the owner read the gadget's playback queue with
  `snd_pcm_avail_update`. On a kernel PCM that returns the mmap'd pointer,
  which moves only when the driver reports a period boundary, so it can be
  most of a period old, by an amount that depends on where the host's packets
  fall against the period. `snd_pcm_avail` asks the driver for the pointer as
  it is. (The bridge's depth telemetry has always used `snd_pcm_delay`, which
  does the same.)
- With that one call changed, 150 s: the queue found before each write read
  93 to 98 in every second, never above; Playback Pitch 13 to 16; the filter
  held back nothing. The lower of the two levels was the true one all along,
  which is why the harness figure never moved.
- The same run had one unprivileged stall (a 2.25 ms gap at 27 s): the
  outgoing depth was found at 19, under the 32-frame packet floor, the
  direction was primed again on the next ordinary block, and its mean read
  128.3 the following second. That is the reprime rule changed after the
  20:24 trial, now seen to land where it is set.
- The learned offset is kept between runs: the 330 s run wrote -15.39 to
  `state/usb16x16-dante-owner.ppm` and the next two starts read it
  (`seed_from_file=1`).
- The gadget *capture* is still read with `avail_update`, so what the owner
  takes each wake stops at the last period boundary. Whether the live pointer
  there would shorten the outgoing path is a separate variable, not changed.

Staged and matching the repo: owner binary f013b1fd (69d6eb60 and 48d51783
kept beside it), `owner/main.cpp` a4ffb892, `owner/servo.hpp` f95a9af8,
`run-owner.sh` e735ae37 (passes `--ppm-file`). The battery of 21:13 UTC was
taken on 48d51783; the level on f013b1fd is expected to be the same 516 and
has not been measured.

## PLAN 3a step 1: subscription resolution baseline, three cold starts (2026-10-09 22:29-22:35 UTC)

The owner (f013b1fd, unprivileged trial, the Mac idle), plugin 55dee5d8, with
`RUST_LOG="warn,...channels_subscriber=debug,...flows_control_server=info"`,
three starts of 100 s about 20 s apart, the sixteen saved subscriptions
(Ferrofish `Output 49-64`). Seconds from the wrapper's start line to each
"channel ... is receiving data (unicast)":

| Start (UTC) | Channels by the second they began receiving | All sixteen |
|---|---|---|
| 22:29:32 | 6 s: 1, 16; 19 s: 2; 32 s: 3, 13, 14, 15; 45 s: 4; 58 s: 5; 69 s: 6-12 | 69 s |
| 22:31:33 | 5 s: 1, 16; 18 s: 2; 31 s: 3, 13, 14, 15; 45 s: 4; 58 s: 5; 68 s: 6-12 | 68 s |
| 22:33:33 | 5 s: 1, 15, 16; 19 s: 2, 12, 13, 14; 32 s: 3; 45 s: 4; 55 s: 5-11 | 55 s |

- Resolution comes in rounds 13.2 s apart on every start, and a round brings
  in as few as one channel. That is the retry interval read from the source
  (9 s, `channels_subscriber.rs` 1252) plus a query's wait. One start's log
  holds 21 `Err(IoError(Kind(TimedOut)))`, 16 `Err(Kind(NotFound))` and 16
  successes, so most queries in a round fail and are simply asked again a
  round later.
- The Ferrofish's side is not the slow one: it requested the Pi's transmit
  flows within a second of each start.
- So for about a minute after the owner starts, part of the return is
  silent. With a long-lived owner that is paid once per boot, as the plan
  says; it is still the first thing a user would see after a restart.
- Not recorded (nobody at Controller): what Controller showed without a
  reload. `avahi-daemon` was running throughout; step 2 (the same with avahi
  stopped) is a root change and was not made.
- Evidence: the three logs on the Pi's tmpfs
  (`/dev/shm/dante-owner-20261009T2229*`, `2231*`, `2233*`), not copied.

## The level is a draw at each owner start, and it has only gone down (2026-10-09 22:35-23:28 UTC, unprivileged trials)

Eleven `TRIAL=1` owner starts (no memory lock, no real-time priority), the
operator away and the loop declared safe unattended. Each: start, 85 s for the
subscriptions, then a loaded impulse run at 32 frames (0.1 on the other
channels); the first three also a noise probe (0.0 % zeros each). Evidence
`outputs/latency/dante-owner-{trial1,trial2,trial3,ab1..4,gap*}-*` and the
condensed logs in `outputs/latency/dante-owner-starts-20261009/`.

| Start (UTC) | Owner build | Idle before it | Impulses | Level | In-run spread |
|---|---|---|---|---|---|
| (21:13, root) | 48d51783 | | 3,200 | 516 | 0 |
| 22:35 | f013b1fd | about 90 s | 400 | 488 | 0 |
| 22:41 | f013b1fd | 18 s | 400 | 485 | 0 |
| 22:46 | f013b1fd | 18 s | 400 | 477 | 0 |
| 22:53 | 69d6eb60 | 60 s | 400 | 471 | 0 |
| 22:57 | f013b1fd | 23 s | 400 | 465 | 0 |
| 23:01 | 69d6eb60 | 23 s | 400 | 458 | 0 |
| 23:06 | f013b1fd | 23 s | 400 | 451 | 0 |
| 23:11 | f013b1fd | 104 s | 200 | 442 | 0 |
| 23:15 | f013b1fd | 21 s | 200 | 435 | 0 |
| 23:21 | f013b1fd | 121 s | 200 | 430 | 0 (after a stall and reprime at 86 s, before the run) |
| 23:24 | f013b1fd | 20 s | 200 | 412 and 420 | 8 (a stall and an outgoing reprime during the run) |

- Inside a start the level does not move: every run without a reprime in it
  is on one sample. Between starts it steps down by 3 to 9 samples, every
  time, 104 samples (2.2 ms) from 516 to 412 over seventeen owner starts
  (six more, unmeasured, lie between 21:13 and 22:35).
- It is not the build: 69d6eb60 (queue read with `avail_update`) and f013b1fd
  (`snd_pcm_avail`) alternate on the same line. That A/B did confirm the
  pointer fix again: 69d6eb60 read the queue high in 37 and 38 of its 175
  seconds, f013b1fd in none.
- It is not the idle time between starts: 20 s, 104 s and 121 s gaps gave
  steps of 7, 9 and 5. A hypothesis that the Mac sends more than it receives
  while the owner is stopped is refuted by that.
- It is not the two depths the owner sets: outgoing mean 127.9 to 128.1 and
  return mean 144.5 to 145.0 on every start.
- A reprime inside a run moved the level by 8 samples. So a prime that lands
  the pointer exactly `--tx-lead` ahead of the clock does not, by itself,
  give the same round trip twice.
- **Cause: not known.** What is left is on the USB legs: where the Mac's
  input and output timelines sit against each other after the gadget's PCMs
  restart (the AES67 record's "session draw at each gadget PCM restart",
  where only a fresh `usbaudiod` anchor read a known figure), or something in
  how the prime meets the gadget's packet phase. The steady downward
  direction is not explained by either as stated. One root cycle earlier in
  the day went the other way by one sample (RTL 703 at 20:32, harness 516 /
  RTL 704 at 21:13), so whether this happens under root at all is open.

**What this does to the day's headline.** 516 against the AES67 record's 703
compares an aged anchor with a fresh one. The AES67 figure was taken under the
rule that only a fresh anchor reads a known level; the Dante figures were not,
and the level read here has ranged from 516 to 412 on one evening with the
same settings. The owner's transport results stand (spread 0, clean noise
probes, the soak, the hour without an event). The size of the latency
advantage does not, until it is read on a fresh anchor. The 3.9 ms stated in
the entries above is withdrawn as a comparison.

## PLAN 3a step 3, first patch: retry after 1 s (2026-10-09 23:30-23:34 UTC)

`patches/0002-subscriber-retry-after-1s.patch` (one constant in
`channels_subscriber.rs`, 9 s to 1 s), built by `build-patched.sh
xrun-option-retry1 0001 0002` as a third artifact, the pinned source and the
stock product restored and re-hashed. Three cold starts of the owner with it
(unprivileged, 60 s each, the Mac idle), timed as the baseline was.

| | Baseline (plugin 55dee5d8) | With 0002 (plugin 5c6b1c0a) |
|---|---|---|
| Seconds to sixteen receive channels | 69, 68, 55 | 24, 28, 29 |
| Between rounds | 13.2 s | 5.0 to 5.2 s |
| Rounds needed | 5 or 6 | 5 or 6 |
| First channel | 5 to 6 s | 6 s |

- The time to sixteen is cut to under half, as the constant would predict:
  a round is now the query's own wait plus one second.
- The number of rounds is unchanged, so the underlying fault is too: most of
  the sixteen per-channel queries in a round still get no answer. That is the
  next patch if this is to come down to one round (one query or one socket
  for all channels of a device), and step 2 (avahi stopped for one start)
  would say whether the shared port 5353 is why.
- The first of the three starts took three `NETRESYNC` in its first eight
  seconds (128 frames; an unprivileged run, and resolution rounds now come
  five times as often during start-up). The other two took none. Worth
  watching for under root before this plugin replaces 55dee5d8.
- Not seen: Controller. `run-owner.sh` still uses `plugins/xrun-option`
  unless `INFERNO_PLUGIN_DIR` names the new directory.

```
4fad88cf  patches/0002-subscriber-retry-after-1s.patch
5c6b1c0a  plugins/xrun-option-retry1/libasound_module_pcm_inferno.so  (pinned + 0001 + 0002)
```

## 2026-10-09 23:41 UTC and 2026-10-10 13:13-13:26 UTC: the harness finds no return on most opens; it is the Mac not sending

Two root starts of the owner (f013b1fd, plugin 55dee5d8) by the operator,
neither measured: `measure-candidate.sh` never got three consecutive readiness
probes. About a quarter of the 8-impulse probes passed at full level and the
rest returned exact silence (`rawInputPeak=0.0`), 10 of 40, 5 of 40, 9 of 40
and 11 of 40 across four attempts. Every unattended run up to 23:28 UTC had
passed its first three probes. The operator changed nothing in between; DVS,
Dante Via and Dante Controller were running throughout the two days; all
subscriptions green in Controller; `USB 16x16` at 48 kHz on the Mac.

On the Pi both runs were clean: one link at 0.3 s, both directions at 48,000
frames a second, depths 128 and 144, no resync, no fault, 600 s each.

To separate the Mac from the loop the owner gained two peak readings on its
one-second `USB` line: `out_peak` (what the gadget capture delivered on
channels 1 and 2) and `back_peak` (what the Inferno capture returned), in
24-bit units, reset each line (owner 94ecdc6c, `owner/main.cpp` 4b1e849d;
f013b1fd kept beside it). One unprivileged 150 s run with twenty probes, three
of which passed (numbers 3, 14 and 16, at 13:24:15, 13:25:05 and 13:25:14):

- `out_peak` was 2,097,148 (0.25 of full scale, the harness's impulse) in
  exactly the seconds of those three probes, 43 to 44 s, 94 to 95 s and 102
  to 103 s into the run, and 0 in every other second.
- `back_peak` was the same 2,097,148 in the same seconds and 0 otherwise.

So whenever the Mac sent the impulses they came back, and on the seventeen
failing probes nothing left the Mac: the gadget received digital silence. The
owner, the Dante loop and the return are not the fault. This is a Mac-side
output state of the kind recorded on 2026-09-05/06 (AppleUSBAudio zeroing
samples), in a stronger form: whole opens silent. The remedy then was `sudo
killall coreaudiod` on the Mac, which is the operator's to run; it is also a
fresh anchor and the first real exercise of the owner's fault path. Whether
last night's twenty-odd owner starts, each a gadget PCM restart under a Mac
that never closed its streams, put the Mac in this state is not known; the
level stepping down at every one of them fits a Mac whose stream bookkeeping
was drifting.

## After `killall coreaudiod`: the Mac sends again, 563 at 32 frames, and what the level actually is (2026-10-10 13:27-13:33 UTC)

Owner 94ecdc6c as root from 13:27:10 UTC (`run-owner.sh 3600 --log-every 1`),
then `sudo killall coreaudiod` on the Mac by the operator about ten seconds
in. Evidence `outputs/latency/dante-owner-fresh1-*`; the owner's log was read
on the Pi while the run continued and is not copied yet.

- The Mac's silent opens are gone: both wrapper runs passed their first three
  readiness probes. Noise probe 0.0 % zeros. **800 loaded impulses at 32
  frames: 563 samples (11.729 ms), spread 0**, no discontinuity.
- **The owner's fault path, first real exercise.** The host stopped at 9.9 s:
  two `NETRESYNC` of 32 frames as the outgoing depth ran out, then out and
  back both `idle` at 10.0 s. No gadget PCM error was raised at any point (the
  host simply stops; nothing xruns). The host came back at 42.9 s: outgoing
  primed again (found 99, block 48), both `flow`. In between the Inferno side
  sent silence and was otherwise untouched: no prepare, no thread change, no
  flow lost, longest wake gap 1.029 ms. That is the design's central claim,
  seen once.
- **A fault in it:** while the return was idle the gadget queue sat at 240,
  not at the 144 target. In the hundred wakes it takes to decide the host has
  stopped, the queue fills to the slack limit, and nothing removes it. The
  host resumed with the return 84 frames deep (mean 228 at 47 s) and the
  servo spent two minutes steering it down, Playback Pitch as high as +58.
  Changed after this run: on going idle the queue is dropped and primed
  afresh at the target (not built yet).
- **The observation that reframes the level.** The impulse run covered 115 s
  to 316 s of the owner's run. Over that time the return mean went from about
  152 down to 133 and back to 137 and the outgoing mean from 125 to 129, a
  net change of some 15 frames in what the Pi was holding. All 800 impulses
  read 563. So moving the depths with the pitch controls does not move the
  level. In hindsight it cannot: the owner neither makes nor destroys frames
  while a direction flows, so every frame the Mac sends comes back a fixed
  number of frames later in the Mac's own count, whatever the queues are
  doing. A pitch setting only moves frames between the Pi's queue and the
  Mac's driver. The level is fixed at the moment a direction is primed, by
  how many frames are then in the loop, and changes only when frames are
  dropped or inserted (a prime, a reprime, a resync, the Mac re-anchoring).
- What follows, as reading and not yet tested: (1) the 84 surplus frames in
  the return queue at the relink are in this 563, so the same start with the
  idle fault fixed should read near 479; (2) `--tx-lead` and `--rx-queue`
  decide where frames sit and how safe the Pi's queues are, and the level
  moves with them only through what a prime puts in the loop; (3) the level
  stepping down at every owner start yesterday means each stop and start cost
  the Mac's input seven frames or so against its output, and the Mac's output
  going silent after twenty-odd of them may be where that ends; (4) the
  "settling" of the depths after a cold start is the servo finding where the
  Mac wants the frames, not the latency changing.

## Second fresh anchor, idle fault fixed: 507 at 32 frames (2026-10-10 13:36-13:46 UTC)

Owner d4ebd576 as root from 13:36:53 UTC (the return queue is dropped and
primed afresh when the host stops pulling; otherwise as 94ecdc6c), `sudo
killall coreaudiod` on the Mac by the operator 79 s in. Evidence
`outputs/latency/dante-owner-fresh2-*`.

- Noise probe 0.0 % zeros. **800 loaded impulses at 32 frames: 507 samples
  (10.562 ms), spread 0**, no discontinuity, no xrun, lag or error line on the
  Pi during either run.
- The stop and return again cost the Dante side nothing: host gone at 78.9 s
  (two `NETRESYNC` lines of 32 and 33 frames reported, as before), back at
  180.3 s, no gadget PCM error, no prepare. The fix did what it was for: the
  return queue read 144..144 for the whole idle stretch and the return was
  primed three times in all (start, on going idle, and once more when the
  host pulled for a tenth of a second at 85 s).
- Against the first fresh anchor's 563 this is 56 lower. The reading above
  predicted about 84 lower, from the 84 surplus frames the unfixed queue held
  at that relink. Direction right, size two thirds of it. Two anchors cannot
  separate "the prediction is off by 28" from "anchors differ by that much":
  on the AES67 path fresh anchors drew about plus or minus 10.
- After the host returned, the depths were again off their setpoints for two
  minutes (return mean 165.7 at 200 s, outgoing 120.1) and were steered back
  with the level unchanged through all of it (the impulse run covers 300 s to
  515 s; the noise probe before it 258 s to 295 s).
- **Fresh anchor against fresh anchor, one draw each way:** the owner at lead
  128 / queue 144 / Inferno 2 ms reads 507; the AES67 record is 703. That is
  196 samples, 4.1 ms. It is the first comparison made under the same anchor
  rule, and it is one anchor: RTL on it and at least two more anchors are
  owed before it is a figure.

## RTL on the second fresh anchor, and a third anchor: 695 RTL, then 489 (2026-10-10 13:47-13:58 UTC)

Same owner process as the section above (d4ebd576, started 13:36:53 UTC).

- **RTL Utility at buffer 32 by the operator on the 507 anchor: 14.479 ms,
  695 samples**, which is 507 plus 188 exactly. The rule holds on a fresh
  anchor too.
- Third `sudo killall coreaudiod` by the operator at 767 s. The host was away
  far longer this time, about six minutes: the gadget's streams only came
  back when the harness opened the device (a first burst at 1,063.9 s, both
  directions flowing from 1,138.1 s). The operator saw the Mac "taking a
  while to reconnect". Throughout, the owner sat idle with the return queue
  at 144 and the Dante side untouched; no gadget PCM error.
- **400 loaded impulses at 32 frames on that anchor: 489 samples (10.188 ms),
  spread 0**, first three readiness probes passed, no discontinuity, nothing
  on the Pi.

Fresh anchors so far, one owner process each column:

| Owner | Anchor | Harness at 32 | RTL at 32 |
|---|---|---|---|
| 94ecdc6c (return queue left at 240 while idle) | 13:27 | 563 | |
| d4ebd576 (queue primed afresh at 144) | 13:38 | 507 | 695 (14.479 ms) |
| d4ebd576 | 13:49 | 489 | |

Two anchors on the fixed owner differ by 18 samples. That is wider than the
plus or minus 10 the AES67 path drew, on two draws. Both sit about 200 under
the AES67 record's 703 (196 and 214).

## RTL on the third anchor: 677; a fourth restart left CoreAudio unresponsive (2026-10-10 ~14:00-14:30 UTC)

- **RTL Utility at buffer 32 by the operator on the 489 anchor: 14.104 ms,
  677 samples**, 489 plus 188 exactly. Three RTL readings on the owner have
  now matched the harness to the sample or within one (703 on 515/516, 695 on
  507, 677 on 489).
- Fourth `sudo killall coreaudiod` by the operator at 2,725.6 s of the same
  owner process. On the Pi it looks like the others: one reported `NETRESYNC`
  of 33 frames, both directions idle, the return queue primed again at 144,
  no gadget PCM error; a short burst from the host at 2,959.3 s and nothing
  after.
- No measurement: at 14:26 UTC the harness refused with "CoreAudio does not
  expose USB 16x16", and both `usb16x16-latency list` and `system_profiler
  SPAudioDataType` then hung for over a minute on the Mac, although the
  operator saw the device listed. The Mac's audio daemon was not answering.
  Nothing on the Pi explains or shares in this. Four restarts of coreaudiod
  inside an hour is not a use anyone will make of it; it was the available
  way to draw a fresh anchor.

## Third fresh anchor, by the Mac's reboot: 482 harness, 670 RTL (2026-10-10 14:50-15:16 UTC)

The Mac was rebooted at about 14:40 UTC. The Pi was not (up 1 day 14 h, gadget
service active, `usb16x16-aes67` inactive). Statime and then owner d4ebd576
(plugin 55dee5d8) were started by the operator, the owner at 14:50:57 UTC with
`run-owner.sh 3600 --log-every 1`. This anchor differs from the two above in
how it was drawn: the Mac's audio stack was new from boot and the owner
started after it, one link each way at start and none since, where the other
two were coreaudiod restarts under a running owner. Evidence
`outputs/latency/dante-noise-ch2-32f-20261010T145149Z*` and
`dante-roundtrip-32f-20261010T145231Z*`.

- The Mac is healthy after the reboot. Noise probe at 32 frames, 0.1 load on
  the other channels: 0.0 % zeros in a 1,244,930-sample span, no zero run of
  4 or more. All three readiness probes passed first time on both runs.
- **800 loaded impulses at 32 frames: 482 samples (10.042 ms), spread 0**,
  score 1.000, no discontinuity in or out, no xrun or lag line on the Pi.
- **RTL Utility at buffer 32 by the operator on the same start: 13.958 ms,
  670 samples**, 482 plus 188 exactly. Fourth RTL reading on the owner to
  match the harness (703 on 515/516, 695 on 507, 677 on 489, 670 on 482).
- The owner at 1,524 s: `tx_links=1 tx_reprimes=0 rx_primes=1`, no resync,
  fault, detach or overflow, longest wake gap 1.0 ms, depths 128.0 / 144.0,
  pitch 1000015 both ways. Opening and closing the device for the harness and
  for RTL produced no link event.
- The wrapper's `error_lines` count rose during both runs (172 by the end of
  the impulse run). Every one is Inferno's control server logging `received
  unknown opcode1` (0x00 and 0x2204) with the packet beside it: control
  requests it does not implement, nothing on the audio path. The count is not
  a fault count on this endpoint.

Fresh anchors on the fixed owner:

| Owner | Anchor | Drawn by | Harness at 32 | RTL at 32 |
|---|---|---|---|---|
| d4ebd576 | 13:38 | coreaudiod restart, owner running | 507 | 695 (14.479 ms) |
| d4ebd576 | 13:49 | coreaudiod restart, owner running | 489 | 677 (14.104 ms) |
| d4ebd576 | 14:50 | Mac reboot, owner started after | 482 | 670 (13.958 ms) |

Three anchors span 25 samples (0.52 ms), against about plus or minus 10 on
the AES67 path; their mean is 493 harness, 681 RTL (14.18 ms). All three sit
196 to 221 under the AES67 record's 703 / 891. The lowest is the one where
the owner was started under a fresh Mac and the two higher ones were relinks
of a running owner; three draws do not say whether that is the method or the
scatter. Not ACCEPTED: the battery (four loaded runs and the soak on one
fresh anchor), a `usb-16x16.service` restart under the owner, bit
transparency and the loaded hour are owed.

## Four loaded runs on the 482 anchor; the soak did not fit the owner's hour (2026-10-10 15:35-15:46 UTC)

Same owner process as the section above (d4ebd576, started 14:50:57 UTC with
a 3,600 s timer), RTL Utility closed. Three more loaded 800-impulse runs at
32 frames back to back, 0.1 load on the other fifteen channels. Evidence
`outputs/latency/dante-roundtrip-32f-20261010T153504Z*`, `T153839Z*`,
`T154214Z*`, with `T145231Z*` from the section above as the first of four.

| Run (UTC) | Impulses | Level | Spread | Score |
|---|---|---|---|---|
| 14:52 | 800 | 482 (10.042 ms) | 0 | 1.000 |
| 15:35 | 800 | 482 | 0 | 1.000 |
| 15:38 | 800 | 482 | 0 | 1.000 |
| 15:42 | 800 | 482 | 0 | 1.000 |

- **3,200 loaded impulses at 482 samples, spread 0, across 53 minutes of one
  owner start**, with RTL Utility opened and closed in between. No
  discontinuity in or out, readiness probes passed first time on every run,
  no xrun or lag line on the Pi.
- The owner at 3,296 s: `tx_links=1 tx_reprimes=0 rx_primes=1`, no resync,
  fault, detach or overflow, no `NETRESYNC` line, longest wake gap in the
  hour 1.098 ms, depths 127.0 / 144.4.
- **The ten-minute sixteen-channel soak was not run.** The owner's timer
  ended at about 15:51 UTC and the soak needs the anchor it is judged on: a
  new owner start primes both directions again and is a different draw. The
  battery is therefore four of four loaded runs with the soak owed, on a
  start made with `run-owner.sh 0` so the timer cannot cut it.

## Full battery on one owner start: 4 x 800 at 482, soak PASS; the level did not step at the owner restart (2026-10-10 15:49-16:14 UTC)

The 14:50:57 owner was stopped by the operator at 3,476 s (`exit=0`, one link
each way for its whole run, no resync, fault or detach) and d4ebd576 started
again at 15:49:01 UTC with `run-owner.sh 0 --log-every 1`, plugin 55dee5d8.
The Mac was not touched: its anchor is the one from the 14:40 reboot, carried
through one owner stop and start. RTL Utility closed throughout. Evidence
`outputs/latency/dante-noise-ch2-32f-20261010T154920Z*`,
`dante-roundtrip-32f-20261010T15{5000,5335,5710}Z*`, `T160045Z*`,
`dante-soak-600s-32f-20261010T160420Z*`.

| Step (UTC) | Result |
|---|---|
| Noise probe, 15:49 | 0.0 % zeros in 1,244,930 samples, no zero run of 4 or more |
| 800 loaded impulses, 15:50 | 482 (10.042 ms), spread 0, score 1.000 |
| 800 loaded impulses, 15:53 | 482, spread 0, score 1.000 |
| 800 loaded impulses, 15:57 | 482, spread 0, score 1.000 |
| 800 loaded impulses, 16:00 | 482, spread 0, score 1.000 |
| 600 s soak, all 16 channels at 0.1, 16:04 | PASS: every channel returned, longest zero run 1, no discontinuity |

- **The battery passed on one start: noise probe clean, 3,200 loaded
  impulses at 482 samples spread 0, ten-minute sixteen-channel soak PASS.**
  All at 32 frames; readiness probes passed first time on every step; no
  xrun or lag line on the Pi.
- The owner at 1,543 s: `tx_links=1 tx_reprimes=0 rx_primes=1`, no resync,
  fault, detach or overflow, no `NETRESYNC` line, longest wake gap 1.095 ms,
  depths 128.0 / 144.2, pitch 1000015 both ways.
- **The level did not move at the owner restart: 482 before, 482 after.** On
  2026-10-09 every owner start stepped it down 3 to 9 samples (516 to 412
  over seventeen starts). One restart is one counter-example, not a
  retraction: it was a single clean stop and start under a Mac booted an hour
  earlier, where the seventeen were on an anchor already aged and several
  were unprivileged trials. It does say the step is not a property of every
  owner start.
- With the previous section this anchor now carries 6,400 loaded impulses at
  482 across two owner starts and 84 minutes, and RTL 670 (13.958 ms) taken
  on the first of the two.
- Not marked ACCEPTED here. What the battery was run on is an owner restart
  on the reboot's anchor, not a draw of its own, and RTL was read on the
  start before; whether that stands as the fresh-anchor battery is the
  operator's decision. Still owed whatever that decision is: a
  `usb-16x16.service` restart under the running owner, bit transparency
  through the owner, the loaded hour.

## ACCEPTED 2026-10-10: the owner at lead 128 / return queue 144 / Inferno 2 ms

After the battery the operator read RTL Utility at buffer 32 on the battery's
own start (owner d4ebd576, 15:49:01 UTC): **13.958 ms, 670 samples**, the same
as on the start before and 482 plus 188 exactly. He accepted the battery as
run, on the reboot's anchor carried through one owner restart.

Point of record for the Dante path, at 32 frames: **harness 482 samples
(10.042 ms), RTL 670 (13.958 ms)**, owner d4ebd576, plugin 55dee5d8
(`XRUN_REPORT "0"`), `config/asound-inferno-owner.conf`, lead 128, return
queue 144, Inferno latency 2 ms, Statime as the clock, run by hand as root
with `run-owner.sh`. The AES67 record for scale is 703 / 891 (18.563 ms):
221 samples, 4.6 ms, lower on this anchor. The figure is this anchor's; the
two earlier fresh anchors on the same owner read 507 / 695 and 489 / 677, so
a start can sit up to 25 samples higher.

The acceptance covers the operating point's level and stability. Not covered
and still owed: a `usb-16x16.service` restart under the running owner, bit
transparency through the owner, the loaded hour, and everything about
persistence (nothing is installed, nothing starts at boot, the AES67 unit is
still enabled).

## `usb-16x16.service` restarted under the running owner: 1.8 s to audio, Dante side untouched; new draw 476 / 664 (2026-10-10 16:43-16:50 UTC)

The fault path that had never been exercised: the gadget itself going away.
`sudo systemctl restart usb-16x16.service` by the operator at 16:43:58 UTC,
3,296 s into owner d4ebd576 (started 15:49:01 UTC, the accepted battery's
process). Evidence `outputs/latency/dante-noise-ch2-32f-20261010T164416Z*`,
`dante-roundtrip-32f-20261010T164456Z*`.

| Owner time | Log line |
|---|---|
| 3,296.331 s | `USBCLOSE reason=-19 (No such device)`; `USBLINK usb=absent tx=idle rx=idle`, `playback_faults=1` |
| 3,297.331 s | `USBOPEN`, `USBLINK usb=open tx=idle rx=idle rx_primes=2` |
| 3,298.132 s | `USBLINK usb=open tx=flow rx=flow tx_links=2`, `tx_prime_found=114` (80 at the first link) |

- **The owner stayed up and relinked by itself: 1.8 s from the device
  vanishing to both directions flowing.** `detaches=1`, one playback fault
  (the -19), no capture fault. No Inferno prepare, no `NETRESYNC` line,
  `tx_resyncs=0 rx_resyncs=0`, no lost frames, the same seven threads at the
  same priorities. `rx_idle_discards=37632` is the return discarded while no
  host was pulling.
- **The Mac re-enumerated and resumed streaming without a coreaudiod kill**
  or any action on it.
- The servos were off their setpoints just after the relink (outgoing mean
  117.0, pitch_c 1000020 at 3,307 s) and back by 3,577 s (129.2 / 144.0,
  pitch 1000015 both ways), as on the earlier relinks.
- Noise probe at 32 frames: 0.0 % zeros in 1,244,936 samples, no zero run of
  4 or more. **800 loaded impulses: 476 samples (9.917 ms), spread 0**, score
  1.000, no discontinuity, no xrun or lag line on the Pi.
- **RTL Utility at buffer 32 by the operator on this draw: 13.833 ms, 664
  samples**, 476 plus 188 exactly. Fifth RTL reading on the owner to match
  the harness.

Fresh draws on d4ebd576:

| Anchor (UTC) | Drawn by | Harness at 32 | RTL at 32 |
|---|---|---|---|
| 13:38 | coreaudiod restart, owner running | 507 | 695 (14.479 ms) |
| 13:49 | coreaudiod restart, owner running | 489 | 677 (14.104 ms) |
| 14:50 | Mac reboot, owner started after (ACCEPTED on this one) | 482 | 670 (13.958 ms) |
| 16:44 | `usb-16x16.service` restart, owner running | 476 | 664 (13.833 ms) |

Four draws span 31 samples (0.65 ms), mean 488.5 harness, 676.5 RTL
(14.09 ms). The gadget restart is the way to draw one from here on: it took
the Mac two seconds, where a coreaudiod restart took it up to six minutes and
four of them broke its audio. The accepted record stays 482 / 670; this draw
had no battery.

## Owner 22fd2622: the host stop no longer resyncs; two stalls on its first start, none on its second (2026-10-10 16:53-17:18 UTC)

**The change.** In `service_tx`, a flowing direction that receives nothing on
a wake while the Inferno pointer is within `capture.period + kResyncMargin`
(64) frames of the clock goes `idle` on that wake, and the existing top-up
then holds the lead with silence. Before, it stayed in `flow` for
`kIdleWakes` (100 wakes) and the clock passed the pointer on every one: the
98 resyncs of the earlier host stops. One late block leaves the depth near 80
and does not trip it; the second empty wake in a row (depth near 32) does,
and that case already ended in a resync and a re-prime. The return to flow is
the same idle, armed, prime sequence as before. Source e53c8407, built on the
Pi with the owner stopped; d4ebd576 kept as `usb16x16-dante-owner-d4ebd576`
(`OWNER_BIN=`). The owner it replaced exited clean at 3,981 s: no resync, the
one detach from the gadget restart.

**First start, 16:55:59 UTC (operator), cable pulled and replugged by him.**
Evidence `outputs/latency/dante-topup-*-20261010T1658*`, `T165902Z*`.

| Owner time | Event |
|---|---|
| 4.2 s | A 6.018 ms gap in the loop's wakes: 2 resyncs (255 frames), gadget playback -32, 2 re-primes, relinked inside the second |
| 81.3 s | Cable pulled: outgoing depth 30 at its lowest, `tx=idle`, **no resync, no `NETRESYNC` line** |
| 81.4 s | Return idle, queue primed again at 144 |
| 81-90 s | Lead held with silence (depth 80 before each top-up), queue 144..144 |
| 90.4 s | Cable back: a 3.675 ms gap, one resync of 49 frames while idle (silence only) |
| 91.2 s | Both directions flowing, `tx_prime_found=108` |

- **The host stop cost no resync** (`tx_resyncs` 2 before it, 2 after it).
  That is the check the change was made for.
- The 6 ms gap at 4.2 s is not explained. Nothing of the kind on the day's
  two earlier starts or on this build's second start. The new code is one
  comparison and cannot block; a link is not excluded by one clean start.
- The 3.7 ms gap at the replug was not seen at the `usb-16x16.service`
  restart on d4ebd576 (no resync there). A physical reconnect and a gadget
  restart are different events on the Pi; whether the gap belongs to the
  reconnect is not known from one of each.
- After the return: noise probe 0.0 % zeros; **800 loaded impulses 470
  samples (9.792 ms), spread 0**, largest wake gap since the replug 1.148 ms.

**Second start, 17:11:02 UTC (stopped and started over ssh, detached; the
operator gave standing permission for owner and service starts and stops at
about 17:05 UTC).** The first start exited clean at 899 s. Evidence
`outputs/latency/dante-topup-*-20261010T171320Z*`, `T171400Z*`.

- One link each way at 0.3 s and nothing after: no resync, re-prime or
  fault to 397 s, largest wake gap 1.063 ms.
- Noise probe 0.0 % zeros; **800 loaded impulses 466 samples (9.708 ms),
  spread 0**.
- **The level stepped down 4 at this owner restart (470 to 466).** The
  15:49 restart on the reboot's anchor did not step (482 to 482). Yesterday's
  steps were 3 to 9 per start. So the step is real and not constant; the
  anchor's age, or what happened on it since (here a gadget restart and a
  cable pull), is what differs between the two cases.

Levels on 2026-10-10 after the reboot, one Mac boot throughout:

| Start / event (UTC) | Owner | Harness at 32 |
|---|---|---|
| 14:50 owner start after the reboot | d4ebd576 | 482 (RTL 670), ACCEPTED |
| 15:49 owner restart | d4ebd576 | 482 |
| 16:44 `usb-16x16.service` restart | d4ebd576 | 476 (RTL 664) |
| 16:57 cable pull and replug, new owner start before it | 22fd2622 | 470 |
| 17:11 owner restart | 22fd2622 | 466 |

22fd2622 is the binary on the Pi and is not accepted: it has had no battery
and no RTL reading. d4ebd576 remains the point of record.

## RTL Utility readings without the operator: driven from the session, read from its own log (2026-10-10 17:23-17:30 UTC)

The operator asked for a way to take RTL readings that can be accepted as his
are. It is the same instrument with the same settings, pressed from the
session, and the figure is taken from the file RTL Utility itself writes, not
from a screenshot.

- **RTL Utility keeps a record of every measurement**:
  `~/Library/Logs/RTL Utility/RTL Utility measurements log.txt`, one line per
  press of Measure RTL with local time, device, input channel, sample rate,
  buffer, reported latency, measured samples and ms, return level,
  correlation and its own Valid flag. `RTL Utility application log.txt`
  beside it names the devices each side opened. The operator's readings of
  the day are all there and match what he reported: 695 at 13:49 UTC, 677 at
  14:20, 670 at 15:16 and again four times at 16:41 (the battery's start),
  664 at 16:49.
- **One reading the record adds:** three presses at 16:56:49-51 UTC read
  664, on owner 22fd2622's first start, after its 6 ms gap and before the
  cable pull. That is harness 476: the level did not move at the d4ebd576 to
  22fd2622 owner restart, nor at the two re-primes the gap forced. With
  15:49 that is two owner restarts without a step and one (17:11) with a
  step of 4.
- **Procedure.** RTL Utility opens on the default device (MHLink, 512). Set
  Input to USB 16x16 first, then Output to USB 16x16, then the buffer to 32;
  output 1 and input 1 are ticked by default. The three menus need the
  screen (computer use, full control); after that Measure RTL is an ordinary
  button and can be pressed in the background while the app stays open.
  Before pressing, the application log must show `CoreAudio: Opened: USB
  16x16` for both sides. `work/latency-harness/read-rtl-log.sh [COUNT]
  [HARNESS] [BUFFER]` then reads the newest lines, refuses anything that is
  not the standard reading or that the app marked invalid, checks harness
  plus 188 when the harness level is given, and saves the lines under
  `outputs/latency/rtl-utility-32f-<UTC>.txt`.
- **The mistake to avoid, made once here:** choosing the output first and
  the input second left the output on the MacBook Pro speakers while the
  menu read USB 16x16 (two channels listed, reported latency 1078). Two
  presses sent the test signal to the laptop speakers and, after Reset audio
  device put everything back on MHLink, one press sent it to MHLink output 1
  at 512 frames. All three returned no reading. Nothing reached the gadget.
- **Result on the 17:11 start of 22fd2622 (harness 466): RTL 654 samples,
  13.625 ms, twice** (17:28:59 by a screen click, 17:29:19 by a background
  press), reported 312, return -21.6 dB, correlation 50.1, Valid: the same
  reported latency, level and correlation as every reading the operator
  took, and 466 plus 188 exactly. Evidence
  `outputs/latency/rtl-utility-32f-20261010T172949Z.txt`. The owner showed
  no link event while RTL opened the device.

What makes such a reading equivalent to his: the instrument, device,
channels, rate and buffer are the same and are in the app's own line; the
line is written by RTL Utility, so a misread screen cannot enter the record;
and the harness on the same start supplies an independent check to the
sample. What it does not replace is his eye on the app when the Mac's audio
is misbehaving. Whether these stand as acceptance readings is his decision.

## The RTL figure from the command line: the harness now reports the DAW timeline itself (2026-10-10 18:50-18:56 UTC)

The operator asked whether the RTL figure can be had from a command, without
RTL Utility or computer use. It can, and the plus-188 rule turns out not to
be an empirical constant but a number the harness was already handed.

- **Where the 188 comes from.** In every IOProc callback CoreAudio gives the
  harness an input buffer and an output buffer, each with its device sample
  time. The harness measures on the device timeline (when the impulse's
  sample left against when it came back). A program that counts in the
  frames it is handed, which is what RTL Utility and a DAW do, sees that lag
  plus the distance between the two buffers of one callback: output sample
  time less input sample time. On the gadget that distance is 188 at 32
  frames and 252 at 64 (two buffers plus 124 of safety offsets and device
  latency). The saved runs already had it: `firstOut` less `firstIn` in
  every `settle.log` of the day is 188.
- **The change.** `LiveImpulseMeasurement.swift` tracks that offset on every
  callback and the report carries `ioOffsetMinimumSamples` /
  `ioOffsetMaximumSamples`; `measure-candidate.sh` prints
  `daw_timeline=<ms> (<samples>) = <median> + io_offset <n> (steady)`, or
  `VARIED lo..hi` if it moved inside the run. The harness's 11 tests pass;
  the signed app was rebuilt with `build-app.sh`.
- **Checked against RTL Utility at two buffer sizes on one owner start**
  (22fd2622 from 17:11:02 UTC, 102 minutes in, one link each way and no
  event since its start; RTL Utility quit before the harness ran):

| CoreAudio buffer | RTL Utility (its log) | Harness lag | io offset | Harness `daw_timeline` |
|---:|---:|---:|---:|---:|
| 32 | 654, 13.625 ms (17:28:59 and 17:29:19 UTC) | 466 | 188, steady | 654, 13.625 ms |
| 64 | 718, 14.958 ms (18:53:31 UTC) | 466 | 252, steady | 718, 14.958 ms |

  200 impulses each, spread 0, no discontinuity. Evidence
  `outputs/latency/dante-dawtl-roundtrip-32f-20261010T185351Z*`,
  `dante-dawtl-roundtrip-64f-20261010T185456Z*`,
  `rtl-utility-64f-20261010T185338Z.txt`,
  `rtl-utility-32f-20261010T172949Z.txt`.
- **What this gives:** `measure-candidate.sh 32 800` now yields the figure
  RTL Utility would show, measured over 800 impulses with their spread, with
  the Pi's counters read before and after, and with the offset checked on
  every callback instead of assumed. RTL Utility takes one correlation per
  press. The two agree to the sample at both sizes here and the plus-188
  relation had held on every pair since 2026-09-06.
- **What it does not give:** an instrument independent of the harness. If
  the harness's own timestamps were wrong, both of its lines would be wrong
  together; RTL Utility remains the outside check, and
  `read-rtl-log.sh` the way to read it. `measure-under-service.sh` (the
  AES67 wrapper) does not print the line yet.

Whether `daw_timeline` may stand in for the RTL reading in an acceptance is
the operator's decision.

## Owner 22fd2622: three more clean starts, then a fresh anchor and the full battery: 506 harness, 694 on the DAW timeline (2026-10-10 19:12-19:39 UTC)

Run from the session with no operator action after he added
`/etc/sudoers.d/usb16x16-dante` (NOPASSWD for `run-owner.sh`, the Statime
binary, the two `pkill -INT` lines and `systemctl restart usb-16x16.service`;
he was told that both paths are writable by his account). Earlier the same
`sudo -n` had only worked inside his own sudo window: the Pi has
`timestamp_type=global`. The 17:11 owner was stopped at 7,227 s, clean, no
resync or re-prime in two hours.

**The 6 ms gap did not come back.** Three starts of 22fd2622 (19:12:04,
19:12:31, 19:12:57 UTC), 25 s watched on each: one link each way at 0.3 s,
no resync, no fault, largest wake gap 1.014, 1.020 and 1.021 ms. With the
17:11 start that is four clean starts after the one that stalled at 4.2 s.
It is still unexplained and is now a one-in-five event at most.

**Fresh anchor.** `sudo systemctl restart usb-16x16.service` at 19:13:35 UTC,
38 s into the third start. Gadget gone at 38.121 s (-19), back and primed at
39.222 s, both directions flowing at 39.422 s: 1.3 s. One `NETRESYNC` of 61
frames at 38.221 s inside a 3.943 ms wake gap, while the direction was
already idle (silence only). The same event on d4ebd576 at 16:43 showed no
resync, and this build's cable replug showed a 3.7 ms gap: two of two device
arrivals or departures on 22fd2622 with a gap of nearly 4 ms, none recorded
on d4ebd576 in one. The changed code is not on that path (the direction is
idle or detached by then), but the pairing is noted and not explained.

**Battery on that anchor, 32 frames, one owner process.** Evidence
`outputs/latency/dante-22fd-*-20261010T19*`.

| Step (UTC) | Result |
|---|---|
| Noise probe, 19:13 | 0.0 % zeros in 1,244,906 samples, no zero run of 4 or more |
| 800 loaded impulses, 19:14 | 506 (10.542 ms), spread 0; `daw_timeline` 694 (14.458 ms), offset 188 steady |
| 800 loaded impulses, 19:18 | 506, spread 0; 694, steady |
| 800 loaded impulses, 19:21 | 506, spread 0; 694, steady |
| 800 loaded impulses, 19:25 | 506, spread 0; 694, steady |
| 600 s soak, all 16 channels at 0.1, 19:28 | PASS: every channel returned, longest zero run 1, no discontinuity |

- **Battery passed: 3,200 loaded impulses at 506 samples spread 0, soak
  PASS, noise probe clean; the RTL-equivalent figure is 694 samples,
  14.458 ms** (`daw_timeline`, accepted by the operator as that figure
  earlier the same day; RTL Utility was not opened).
- The owner at 1,576 s: two links each way (start, and the gadget restart),
  no re-prime, the one resync above, no fault but the -19, largest wake gap
  since the relink 1.068 ms, depths 128.1 / 143.4, pitch 1000014 both ways.
- The first impulse run began 60 s after the relink with the servos still
  off their setpoints (return mean 165 at 58 s); its level is the same 506
  as the three after it.

Fresh draws on the day, both builds:

| Anchor (UTC) | Drawn by | Owner | Harness | RTL or `daw_timeline` |
|---|---|---|---|---|
| 13:38 | coreaudiod restart | d4ebd576 | 507 | 695 |
| 13:49 | coreaudiod restart | d4ebd576 | 489 | 677 |
| 14:50 | Mac reboot, owner started after | d4ebd576 | 482 | 670 (ACCEPTED) |
| 16:44 | gadget restart | d4ebd576 | 476 | 664 |
| 16:57 | cable pull and replug | 22fd2622 | 470 | |
| 19:13 | gadget restart | 22fd2622 | 506 | 694 |

Six draws span 37 samples (0.77 ms), 470 to 507. The earlier ones looked like
a slow decline through the day; this one is back at the top, so it was not a
decline: a draw lands anywhere in a band about 0.8 ms wide, and a start's
figure is its draw. The honest figure for the path is therefore the band,
about 14.2 ms plus or minus 0.4 at 32 frames by RTL, not any one anchor.

Not marked ACCEPTED: the operator decides. 22fd2622 has now had the battery
that d4ebd576's acceptance rested on, on a fresh anchor of its own, plus the
host-stop check it was built for.

## ACCEPTED 2026-10-10: owner 22fd2622 replaces d4ebd576 as the point of record

Accepted by the operator after the 19:12-19:39 UTC battery, with the RTL
figure taken from the harness's `daw_timeline` under his decision of the same
day.

Point of record for the Dante path, at 32 frames: **harness 506 samples
(10.542 ms), `daw_timeline` 694 (14.458 ms) on its battery's anchor**; owner
22fd2622 (source e53c8407), plugin 55dee5d8 (`XRUN_REPORT "0"`),
`config/asound-inferno-owner.conf`, lead 128, return queue 144, Inferno
latency 2 ms, Statime as the clock, started by `run-owner.sh`. The figure is
that anchor's: fresh draws on the day span 470 to 507 (RTL 658 to 695, about
14.2 ms plus or minus 0.4), and the AES67 record for scale is 703 / 891
(18.563 ms).

Against d4ebd576 the only change is the host stop: idle on the second empty
wake and silence from there, no resync, where d4ebd576 resynced about 98
times in 100 ms. d4ebd576 stays on the Pi as the fallback
(`OWNER_BIN=usb16x16-dante-owner-d4ebd576`), with its own acceptance at
482 / 670.

Carried into the acceptance as open, not as conditions: one start in five of
22fd2622 had a 6 ms loop gap at 4.2 s; both times the gadget left or returned
under it there was a wake gap of nearly 4 ms. Neither is explained and
neither has a like-for-like count on d4ebd576.

Not covered and still owed: plugin 5c6b1c0a as root, bit transparency
through the owner, the loaded hour, persistence (nothing installed, nothing
at boot, the AES67 unit still enabled).

## Plugin 5c6b1c0a (retry after 1 s) as root: 31, 28 and 28 s to sixteen receive channels against 69 s; no resync (2026-10-10 19:49-19:58 UTC)

Owner 22fd2622 as root with memory lock and real-time priority, the Mac
streaming, cold starts 15 s after the previous owner's exit, timed as the
unprivileged baseline was (seconds from the wrapper's START line to each
`is receiving data (unicast)`), with
`RUST_LOG=warn,inferno_aoip::device_server::channels_subscriber=info`.
`run-owner.sh` (cbdebab4) now takes `INFERNO_PLUGIN_DIR=`, `INFERNO_CONFIG=`,
`RUST_LOG=`, `OWNER_BIN=` and `NO_USB=` as arguments after SECONDS, because
the sudo rule does not pass the caller's environment.

| Start (UTC) | Plugin | Channels by the second they began receiving | All sixteen |
|---|---|---|---|
| 19:49:25 | 55dee5d8 (in service) | 6 s: 1, 16; 19 s: 2; 32 s: 3, 13-15; 45 s: 4; 58 s: 5; 69 s: 6-12 | 69 s |
| 19:50:53 | 5c6b1c0a | 6 s: 1; 11 s: 2; 16 s: 3; 18 s: 4, 14-16; 24 s: 5; 29 s: 6; 31 s: 7-13 | 31 s |
| 19:51:43 | 5c6b1c0a | 5 s: 1, 16; 10 s: 2; 15 s: 12-15; 21 s: 3; 26 s: 4; 28 s: 5-11 | 28 s |
| 19:52:29 | 5c6b1c0a | 5 s: 1, 15, 16; 11 s: 2, 12-14; 16 s: 3; 21 s: 4; 28 s: 5-11 | 28 s |

- **Under root the patch does what it did unprivileged: 28 to 31 s against
  69 s**, rounds about 5 s apart instead of 13 s. The root baseline is the
  unprivileged one to the second (69 against 69, 68, 55), so privilege was
  never the variable.
- **The worry from the unprivileged trial did not materialise:** no
  `NETRESYNC` on any of the three starts, one link each way, no re-prime,
  largest wake gap 1.02 to 1.13 ms. The three resyncs seen on one
  unprivileged start belonged to running without real-time priority.
- Unchanged, as before: five or six rounds are still needed, because most
  per-channel queries in a round get no answer. Getting to one round is a
  different patch (one query per device) or the avahi question (PLAN 3a
  step 2), neither attempted.
- Not judged here: audio through 5c6b1c0a. The patch is one constant in the
  subscriber's retry timer and nothing on the audio path, but the plugin is
  a different binary and has had no noise probe, harness run or soak.

Afterwards the accepted configuration was put back: owner 22fd2622 on plugin
55dee5d8, started 19:53:25 UTC, detached. On it, 75 s in: noise probe 0.0 %
zeros; 200 loaded impulses 492 samples spread 0, `daw_timeline` 680
(14.167 ms), offset steady. So the Mac is healthy after five more owner
starts, and the level went from 506 to 492 across those five restarts, about
3 a start, the size of yesterday's steps. Evidence
`outputs/latency/dante-after-retry-*-20261010T19*`; the four timing logs are
on the Pi's tmpfs (`/dev/shm/dante-owner-20261010T1949*` to `T1952*`), not
copied.

## Plugin 5c6b1c0a in service: full battery on a fresh anchor, 473 harness, 661 on the DAW timeline (2026-10-10 20:04-20:31 UTC)

The operator said 5c6b1c0a can go in service and asked for its battery.
Owner 22fd2622 started on it at 20:04:22 UTC (root, detached), gadget restart
at 20:05:07 UTC for a fresh anchor, then the battery on that one process.
Evidence `outputs/latency/dante-5c6b-*-20261010T20*`.

- The gadget restart, 45 s in: gone at 45.0 s, both directions flowing at
  46.3 s, **no resync and no wake gap this time** (largest in the run's first
  minute 1.022 ms). So the gap of nearly 4 ms seen at the two earlier device
  events on 22fd2622 is not something every such event produces.

| Step (UTC) | Result |
|---|---|
| Noise probe, 20:05 | 0.0 % zeros in 1,244,939 samples, no zero run of 4 or more |
| 800 loaded impulses, 20:06 | 473 (9.854 ms), spread 0; `daw_timeline` 661 (13.771 ms), offset 188 steady |
| 800 loaded impulses, 20:09 | 473, spread 0; 661, steady |
| 800 loaded impulses, 20:13 | 473, spread 0; 661, steady |
| 800 loaded impulses, 20:16 | 473, spread 0; 661, steady |
| 600 s soak, all 16 channels at 0.1, 20:20 | PASS: every channel returned, longest zero run 1, no discontinuity |

- **Battery passed on 5c6b1c0a: 3,200 loaded impulses at 473 spread 0, soak
  PASS, noise probe clean; RTL-equivalent 661 samples, 13.771 ms.** No xrun
  or lag line on the Pi during any step.
- The owner at 1,586 s: no resync at all in the run (`tx_resyncs=0`), two
  links each way (start and the gadget restart), no re-prime, largest wake
  gap since the relink 1.073 ms, depths 128.0 / 144.0, pitch 1000015.
- 473 is inside the day's band of fresh draws (470 to 507), as expected: the
  patch is one constant in the subscriber's retry timer.
- `run-owner.sh` now defaults to `plugins/xrun-option-retry1`; 55dee5d8
  stays in `plugins/xrun-option` and is selected with
  `INFERNO_PLUGIN_DIR=.../plugins/xrun-option`.

In service by the operator's decision, with the battery behind it. The word
ACCEPTED for owner 22fd2622 on plugin 5c6b1c0a as the point of record is his
to give; until then the record is 22fd2622 on 55dee5d8 at 506 / 694.

## ACCEPTED 2026-10-10: owner 22fd2622 on plugin 5c6b1c0a is the point of record

Accepted by the operator after the 20:04-20:31 UTC battery. Point of record
for the Dante path, at 32 frames: **harness 473 samples (9.854 ms),
`daw_timeline` 661 (13.771 ms) on its battery's anchor**; owner 22fd2622
(source e53c8407), plugin 5c6b1c0a (patches 0001 `XRUN_REPORT` and 0002 retry
after 1 s), `config/asound-inferno-owner.conf`, lead 128, return queue 144,
Inferno latency 2 ms, Statime as the clock, started by `run-owner.sh`
(2bd5dde1), which defaults to this plugin. The figure is one anchor's: fresh
draws on the day span 470 to 507, RTL-at-32 about 14.2 ms plus or minus 0.4;
the AES67 record for scale is 703 / 891 (18.563 ms).

Fallbacks kept on the Pi: plugin 55dee5d8 (`INFERNO_PLUGIN_DIR=.../plugins/xrun-option`,
accepted with 22fd2622 at 506 / 694) and owner d4ebd576
(`OWNER_BIN=usb16x16-dante-owner-d4ebd576`, accepted at 482 / 670).

Carried open: the one 6 ms loop gap in the first seconds of a start (one
start in about a dozen of 22fd2622 by now), and a wake gap of nearly 4 ms at
two of three device arrivals or departures. Owed: bit transparency through
the owner, the loaded hour, persistence.

## Bit transparency from the Mac through the owner: PASS on what a Mac can send; macOS itself applies a gain of 0.999998 each way (2026-10-10 21:20-22:15 UTC)

Owner 22fd2622 on plugin 5c6b1c0a, the 20:04:22 UTC process, untouched
throughout (no resync, re-prime or fault from before the first run to after
the last, largest wake gap 1.04 ms). Path: Mac -> gadget -> owner -> Dante ->
Ferrofish -> (MADI, Metric Halo) -> Ferrofish -> Dante -> owner -> gadget ->
Mac, sixteen channels, 32 CoreAudio frames. The operator muted the monitors
first: the signal is full-scale noise on every channel.

**The instrument.** `usb16x16-latency bitexact [--seconds N]`, new
(`BitExact.swift`, four unit tests): every output channel carries its own
24-bit sequence of period 2^24 in which each sample predicts the next, and
each input is checked sample for sample for the sequence, the channel it
belongs to, values off the 24-bit grid, and the largest codes. No alignment,
no recording.

**Finding 1: macOS is not bit-exact on this device, in either direction.**
The first trial locked on nothing. Constant levels on output 1, read on the
Pi as the owner's `out_peak` (the raw gadget capture, integer all the way):

| Float sent, as a 24-bit code | Code the gadget received |
|---:|---:|
| 8388607 | 8388590 |
| 8388600 | 8388583 |
| 4194304 | 4194296 |
| 2097152 | 2097148 |
| 1048576 | 1048574 |
| 524288 | 524287 |
| 262144 | 262143 |
| 131072, 65536, 1000, 100, 10, 3, 1 | unchanged |
| -8388608 | -8388591 |

  That is a gain of 0.999998 (between 1 - 2.03e-6 and 1 - 1.97e-6 by these
  points), rounded to nearest. The input side does the same: the harness's
  0.25 impulse arrives at the gadget as 2097148 and comes back to the IOProc
  as 0.24999902, which is 2097148 x 0.999998 / 2^23 and not a whole code.
  Every saved harness run since 2026-09-03 has that same returned peak, so
  it is not new and not the Dante path: it is the Mac's float conversion for
  this device, macOS 26.5.2 today. The device's volume controls read 0 dB
  out (and -10 dB in, which is not applied to the audio). Consequences: a
  program on this Mac cannot send a code beyond +/-8388590 (-0.0000174 dB),
  so "full scale included" cannot be tested, or reached, from the Mac; and
  anything played or recorded through CoreAudio floats is off by that gain
  whatever the Pi does. Whether an integer-format or hog-mode client escapes
  it was not tried.
- For every level in the table the Pi's `back_peak` equalled its `out_peak`:
  what the owner sent to Dante came back the same code, 1 LSB and 8388591
  included.

**The test as run.** The sequence is defined on the codes that reach the
wire: each float is chosen so the host's gain lands it on its code, each
returned float is divided by the gain to recover its code; values beyond
+/-8388590 are held there and the sample after one is passed over, not
judged (about 60 to 70 a channel in ten minutes). The unit tests pass every
sendable code through a model of the host both ways, in float and in double
arithmetic.

| Run (UTC) | Samples matched | Mismatches | Events |
|---|---:|---:|---|
| 21:43, 600 s | 460,784,784 | 225 a channel | one run of 224 zeros on all sixteen channels at once |
| 21:54, 600 s | 460,781,712 | 417 a channel | one run of 416 zeros on all sixteen at once, 451.7 s in |
| 22:04, 600 s, checker fixed | 460,788,384 | 0 | none |

- **Third run: PASS. 460.8 million samples, every one the code that was
  sent, each channel on its own number, nothing off the grid, no zero run
  longer than 1, the largest codes of both signs returned at least 27 times
  on every channel**, no timestamp discontinuity either way. Evidence
  `outputs/latency/dante-bitexact-600s-32f-20261010T220449Z.json`.
- **The two holes in the first two runs were the checker's own doing, as far
  as one clean run can say.** 224 and 416 are 7 and 13 of the Mac's 32-frame
  buffers; all channels went to zero together and came back in sequence;
  nothing happened on the Pi. The first version built a three-element array
  for every sample it generated, 512 heap allocations inside each audio
  callback, which is how an IOProc misses its deadline. With the allocation
  removed the third run had none. One clean run after two with an event each
  is suggestive, not proof; outside the holes those two runs also had no
  mismatch. Evidence `...T214327Z.json`, `...T215403Z.json`.

**What is established.** From gadget capture to gadget playback (owner out,
Inferno transmit and receive on the patched plugin, the Ferrofish and the
Metric Halo loop, owner back) the path is bit-exact at 24 bits for every
code a Mac can produce, up to +/-8388590, in both directions at once, over
ten minutes on all sixteen channels. With the Pi probe's earlier result for
the endpoint alone (true full scale included) nothing on the Pi side is
left unproven except true full scale through the owner's integer copy, which
cannot be driven from this Mac. What is not bit-exact is the Mac.

## The loaded hour: FAIL, two holes of whole 32-frame units on all sixteen channels; and a CORRECTION to the section above (2026-10-10 22:25-23:26 UTC)

`measure-candidate.sh soak 3600 32` (the harness's `continuous` mode, its
limit raised from 600 to 3600 s; sixteen channels at 0.1, one unbroken run),
on owner 22fd2622 / plugin 5c6b1c0a, the 20:04:22 UTC process. Evidence
`outputs/latency/dante-hour-soak-3600s-32f-20261010T222555Z*`.

- **FAIL by the soak's own rule (no zero run of 4 or more): two runs of
  zeros, on all sixteen channels at once.** 224 samples at 1,901.8 s (about
  22:57:40 UTC) and 352 samples at 3,597.5 s (about 23:25:56 UTC). Everything
  else in 172.8 million frames a channel returned; peak 0.1000 on every
  channel; no timestamp discontinuity in or out on the Mac.
- **Nothing on the Pi at either time.** The owner over the hour: no resync,
  no re-prime, no link change (`tx_links=2` before and after), no overflow,
  largest wake gap 1.05 ms, depth means 126.0 to 129.9 and 142.0 to 146.0.
  The journal has no entry within 20 s of any of the events; eth0 shows no
  errors (its `dropped` counter is cumulative since boot and was not read
  before).
- **CORRECTION to the bit-transparency section: the two holes there were not
  the checker's allocation.** The same thing happened here with a different
  IOProc that allocates nothing. Four holes in about 100 minutes of
  all-channel observation this evening: 224, 416, 224, 352 samples, at an
  unknown time in the 21:43 run, 22:01:35, 22:57:40 and 23:25:56 UTC. The
  third bit-exact run was simply ten minutes without one. Its result (460.8
  million samples matched) stands; the attribution does not.
- **What the holes look like.** Each is a whole number of 32-sample units
  (7, 13, 7, 11). They do not start on a Mac buffer boundary on either side
  (the first zero is at input frame 10 modulo 32, and 661 frames earlier on
  the output side, 21 modulo 32). 32 frames is also the size of a Dante
  packet on these flows. The Mac did not stop sending: a stopped host makes
  the owner go idle and relink, and it did not. So either the Mac sent
  zeros for those buffers with its buffers offset from where this arithmetic
  puts them, or 7 to 13 consecutive Dante packets on every flow went
  missing or late in one direction (Pi to Ferrofish, the Ferrofish and
  Metric Halo loop, or Ferrofish to Pi). **Not located.**
- **What it is not known to depend on.** All four were on plugin 5c6b1c0a,
  which has been in service since 20:04 UTC, but the all-channel observation
  on 55dee5d8 today is only twenty minutes (two soaks), and at this evening's
  rate twenty clean minutes would happen nearly half the time. The four
  ten-minute soaks of the day that passed (16:04, 19:28, 20:20 and the third
  bit-exact run) are 40 minutes without a hole. Impulse runs cannot see a
  hole of this size.

**Consequences.** The loaded hour is not passed. The acceptances of the day
rest on ten-minute soaks, each of which is honest for its ten minutes and
too short to see an event that comes about once in 25 minutes. Next is to
locate it: the owner counts all-channel zero runs on the stream it reads
from the gadget and on the stream it reads from Dante, as a diagnostic
build, and a soak is run until a hole occurs. Zeros in the gadget stream put
it on the Mac or USB; zeros only in the Dante stream put it on the network
or the loop; neither puts it after the Pi on the way back.

## The holes are on the Dante side of the owner, not on the Mac or USB (2026-10-10 23:29 to 2026-10-11 00:31 UTC)

Diagnostic owner 0d13ee3c (source 7aa12be8: 22fd2622's code plus counters,
built on the Pi with the owner stopped, kept as
`owner/usb16x16-dante-owner-diag` beside the accepted binary, selected with
`OWNER_BIN=`). On the loop thread it counts runs of frames with all sixteen
channels zero, 8 frames to 100 ms long and ending in signal, separately on
what it reads from the gadget (`out_holes`, what the Mac sent) and on what
it reads from the Inferno capture (`back_holes`, what Dante returned);
count and longest are on the `USB` line and in `USBSUMMARY`. Plugin
5c6b1c0a, started 23:29:09 UTC; one 3,600 s loaded soak from 23:29:58 UTC.
Evidence `outputs/latency/dante-diag-hour-soak-3600s-32f-20261010T232958Z*`.

| | Hole 1 | Hole 2 |
|---|---|---|
| Seen by the Mac (soak) | 288 zeros at 2,012.5 s, all 16 channels | 448 zeros at 2,168.1 s, all 16 |
| Owner, stream from the gadget | none | none |
| Owner, stream back from Dante | 288 frames, by 2,075.1 s of the owner | 448 frames, by 2,231.1 s |

- **`out_holes=0/0`, `back_holes=2/448` for the hour.** The Mac's audio
  arrived at the Pi whole. The zeros are already in what the Inferno capture
  hands the owner, the same lengths to the sample as the Mac then sees. So
  the Mac's output, the USB legs, the gadget and the owner's copy out are
  cleared, and so is everything after the Inferno capture on the way back.
- The hole is therefore somewhere in: Inferno transmit, the network from the
  Pi to the Ferrofish, the Ferrofish and Metric Halo MADI loop, the network
  back, Inferno receive.
- **Inferno said nothing.** No `tx lag` line, no `Lost ... samples`, no flow
  timeout at either time; the capture kept delivering its usual 48 frames a
  wake with zeros in them, which is what the plugin does with samples it
  never received. The owner's loop was on time (wake gap 1.0 ms), outgoing
  depth 79..80 as always.
- The Pi's receive counters do not account for it: `UdpRcvbufErrors` is 132
  in two days of uptime, fewer than this evening's holes would need; softnet
  drops are zero on all four cores. eth0's `dropped` rose by 1,924 in the
  64 minutes between two reads, a steady half a frame a second that does
  not look like bursts of audio packets, but it was not broken down.
- Six holes now, in about 160 minutes of all-channel observation: 224, 416,
  224, 352, 288, 448 samples (7, 13, 7, 11, 9, 14 packets of 32), at
  irregular times.

Also on this start: at 26.1 s a `tx lag of 137 samples` from Inferno, one
resync of 62 frames, a gadget playback underrun and a relink; the second
early-start stall of the day on this code (the other at 4.2 s of a 22fd2622
start). Not connected to the holes by anything seen.

Running on the Pi at the end of this section: the diagnostic owner
0d13ee3c, not the accepted 22fd2622 (same audio code).

## The holes are packets from the Pi reaching the Ferrofish late; plugin 55dee5d8 has them too (2026-10-11 00:37-01:39 UTC)

Diagnostic owner 0d13ee3c on plugin 55dee5d8 from 00:37:25 UTC, one 3,600 s
loaded soak from 00:38:55 UTC. Evidence
`outputs/latency/dante-diag55-hour-soak-3600s-32f-20261011T003855Z*` and the
operator's two Dante Controller screenshots in
`outputs/latency/dante-holes-20261010/`.

- **The older plugin is not free of it: one hole in the hour**, 416 zeros
  (13 packets) on all sixteen channels at 786 s (about 00:52:04 UTC), counted
  by the owner on the stream back from Dante (`back_holes=1/416`,
  `out_holes=0/0`). The retry patch (0002) is cleared. No hole after
  01:12 UTC, when the operator cleared the Ferrofish's latency statistics;
  his Late count for 01:12 to 01:39 was not yet read when this was written.
- **Dante Controller, Latency tabs, read by the operator at about 01:04 UTC,
  27 minutes into this owner process:**

| Receiver | From | Setting | Peak | Average | Late |
|---|---|---|---|---|---|
| USB-16x16-Inferno | FF-PULSE-16-DX | 2 ms | 375 us | 166 us | 0 |
| FF-PULSE-16-DX | USB-16x16-Inferno | 2 ms | 10.1 ms | 567 us | 52 |

  **The Ferrofish received 52 packets from the Pi late, the latest 10.1 ms
  after its time, and none the other way.** 52 is the one hole of that
  period exactly: 13 packets on each of four flows. So a hole is a burst of
  the Pi's transmit packets arriving several milliseconds late at the
  Ferrofish, which discards them. The return leg, the Metric Halo loop and
  Inferno receive are cleared.
- **What it is not.** Not Inferno's transmit thread falling behind by its
  own account: no `tx lag` line at any hole (it logs one at the early-start
  stalls). Not the Pi's clock moving: the owner's outgoing depth, which is
  the pointer against that clock, read 79..80 through every hole. Not the
  receive side: `UdpRcvbufErrors` unchanged at 132 through three hours.
- **What is left:** between the transmit thread's `send` and the Ferrofish:
  the Pi's kernel transmit path, its Ethernet controller, or the switch.
  Read without root: eth0's one interrupt is serviced on CPU 0 only
  (714 million there, none elsewhere, affinity 0-3); `ksoftirqd` and Statime
  are ordinary-priority tasks; the owner's loop and Inferno's two flow
  threads are FIFO 79, 80 and 81 and float over all four cores; governor
  `performance`; kernel 6.18.34+rpt-rpi-2712. A real-time thread sitting on
  CPU 0 while transmit completions wait for softirq there would produce
  exactly a burst of late transmits. That is a hypothesis; nothing measured
  yet says it.
- The operator asked whether the Ferrofish still being in AES67 mode
  matters. Not expected to: these are unicast Dante flows, the Pi follows
  the Ferrofish's PTPv1, which stays up in either mode, and a clock problem
  would show in both directions. Turning it off is a valid single-variable
  test held back for now (a Ferrofish reboot, and it removes the AES67
  rollback while off).

Holes observed in all-channel load, 2026-10-10 evening to 2026-10-11: seven
in about 220 minutes (224, 416, 224, 352, 288, 448, 416 samples).

## Pinning did not stop the holes; the Pi's Ethernet controller has a known transmit-stall fault (2026-10-11 01:43-02:48 UTC)

**The pinned hour: one hole.** `usb16x16-stall-tuning irqs pin` (eth0 and the
gadget interrupt to CPU 1, runtime only) and the whole owner confined to CPUs
2 and 3 (`run-owner.sh` 55e7d65b takes `OWNER_CPUS=`; all seven threads read
back `2-3`, both interrupts `1`). Diagnostic owner 0d13ee3c on plugin
5c6b1c0a from 01:43:10 UTC, 3,600 s loaded soak from 01:44:20 UTC: one hole
of 352 zeros (11 packets) at 534.9 s, on the stream back from Dante only
(`back_holes=1/352`, `out_holes=0/0`); nothing else in the hour, largest wake
gap 1.04 ms. So real-time threads sharing a core with the Ethernet interrupt
is not the cause, or not all of it. The pinning is still in place. Evidence
`outputs/latency/dante-pinned-hour-soak-3600s-32f-20261011T014420Z*`. Eight
holes now in about 280 minutes of all-channel load.

**What the Pi's Ethernet side shows, read without root.**

- No pause frames (the link partner does not advertise them), EEE enabled
  but inactive, no transmit errors or collisions in `ethtool -S`, the queue
  discipline (`fq_codel`) with no drops and an empty backlog, softnet drops
  zero, real-time throttling not triggered (the three FIFO threads use 7, 3
  and 1 % of a core and are never preempted).
- **The kernel log has one line from the driver, from 2026-10-09 18:14 UTC:
  `macb 1f00100000.ethernet eth0: TX stall detected on queue 0 (tail=39899221
  head=39899222); re-kicking TSTART`.** This is the fault recorded on
  2026-09-12 (the handoff's eth0 transmit stall after a link flap).
- It is a known fault of this controller. A patch posted to linux-arm-kernel
  in June 2026 ("net: macb: add TX stall timeout callback") says the MACB in
  the Raspberry Pi's RP1 "suffers from sporadic stalls on the TX queue",
  root cause not fully understood, "likely related to a hardware issue where
  a TSTART write to the NCR register is missed"; its authors reproduce it
  with bulk traffic within hours, and a Talos Linux report counts about 70
  such messages an hour on Pi 5 nodes. The Raspberry Pi kernel's driver
  carries workarounds for a dropped TSTART (a pending flag re-read from the
  interrupt, a read-back to flush the write). The logged message is the
  slow case, caught by a watchdog after seconds.
- **Hypothesis, not yet shown: a hole is the short case of the same fault.**
  A transmit start is missed, packets wait in the controller's ring for 5 to
  10 ms until something starts it again, and they then leave together and
  late. That would be invisible to every counter read so far and would
  match: transmit only, all flows at once, no trace in Inferno.

**The test now running** (from 02:48 UTC): `work/dante-mode/diag/eth-tx-watch.py`
on the Pi, unprivileged on CPU 0, reading eth0's byte-queue `inflight`
(bytes handed to the driver and not yet completed) and `tx_packets` about
2,000 times a second, with another loaded hour. In its first minute:
inflight peak 1,906 bytes, transmit never still for more than 0.64 ms. At a
hole, inflight climbing with `tx_packets` standing still puts the stall in
the controller; `tx_packets` still with nothing in flight puts it before the
driver; nothing at all puts it after the Pi, in the cable or the switch.

## Root cause of the holes: the Ferrofish does not answer the Pi's unicast ARP probes; fixed in the plugin by confirming the neighbour on send (2026-10-11 02:48-03:55 UTC)

**The watched hour** (diagnostic owner 0d13ee3c on 5c6b1c0a, pinned;
`eth-tx-watch.py` on CPU 0; soak from 02:48:03 UTC; evidence
`outputs/latency/dante-txwatch-hour-soak-3600s-32f-20261011T024803Z*` and
`outputs/latency/dante-holes-20261010/eth-tx-watch-20261011T0248Z.log`):

| | Hole 1 | Hole 2 |
|---|---|---|
| Mac (soak) | 416 zeros at 1,676.5 s | 352 zeros at 2,241.7 s |
| Owner `back_holes` | 416 frames, by 03:16:14 UTC | 352 frames, by 03:25:39 UTC |
| Watcher | 03:16:13.096: transmit counter still 9.36 ms, **0 bytes in flight** | 03:25:38.345: still 7.97 ms, **0 bytes in flight** |

- The watcher logged exactly two events in the hour and they are the two
  holes. For 8 to 9 ms no frame left eth0 and nothing was waiting in the
  controller; its own polls were 0.47 ms apart, so it was not asleep. In
  every other minute the counter was never still for more than 0.6 ms.
- **So the controller is cleared**: with a stalled controller the bytes in
  flight would have climbed. The packets were being held above the driver,
  after Inferno's `send` had returned. The transmit-stall hypothesis of the
  section above is withdrawn for the holes (the fault itself is real and was
  logged once this boot; it is not what this is).

**What holds them: the neighbour entry.** `ip -s neigh show` for the
Ferrofish (169.254.248.189, 00:1d:c1:1d:27:dc) on eth0, once a second:

```
DELAY (5 s) -> PROBE, probes 1, 2, 3 (one a second) -> DELAY -> PROBE ...
```

  never REACHABLE, an eight-second cycle, and `res_failed` in
  `/proc/net/stat/arp_cache` at about 8,800. Linux confirms a neighbour by
  unicast ARP probes when nothing else tells it the neighbour is alive, and
  UDP tells it nothing. **The Ferrofish does not answer those unicast
  probes.** After the third the entry fails, the next audio packet starts a
  broadcast resolution, and every packet to the Ferrofish, all four flows,
  waits in the neighbour's queue for the reply and then leaves together.
  Usually the reply takes a fraction of a millisecond: that is the second
  bar in the Ferrofish's latency histogram near 0.9 ms, about 200 counts in
  27 minutes, one per eight seconds. Now and then it takes 5 to 10 ms, the
  packets arrive past the Ferrofish's 2 ms and are discarded: a hole.
- This explains every observation: transmit only; all flows at once; whole
  packets; nothing in Inferno's log, the driver's counters, the queue or the
  controller; the other direction clean (the Ferrofish's stack resolves the
  Pi its own way); the AES67 path never showing it (multicast, no ARP);
  both plugins; pinning irrelevant.

**The fix: patch 0003** (`patches/0003-tx-confirm-neighbour-on-keepalive.patch`,
02f420e4): Inferno's transmit thread already reads each receiver's keepalive
(four a second); the first packet it sends on that flow afterwards now goes
with `MSG_CONFIRM`, which tells the kernel the neighbour has just proved
itself, so the entry stays reachable and is never probed. One `extern`
declaration of `send`, no new dependency, flows without keepalives
(multicast) untouched. Built on the Pi by `build-patched.sh
xrun-option-retry1-confirm 0001 0002 0003` with the owner stopped; the
script's pin check now covers `flows_tx.rs`; pinned source and stock product
restored.

```
0ee61f2f  plugins/xrun-option-retry1-confirm/libasound_module_pcm_inferno.so  (pinned + 0001 + 0002 + 0003)
```

- **With it the entry reads REACHABLE, confirmed 0 s ago, every second for
  twenty seconds** (diagnostic owner on it from 03:53:17 UTC, pinning
  unchanged), where it had cycled through failure every eight.
- A loaded hour on it started at 03:54:38 UTC. The mechanism being gone is
  established; that the holes are gone needs that hour and more.
- Other ways to the same end, not used: a permanent neighbour entry for the
  Ferrofish on the Pi (root, and tied to one address), or
  `net.ipv4.neigh.eth0` settings that make re-probes broadcast.
- The diagnostic owner's start on this plugin took two resyncs in its first
  five seconds (267 and 176 frames): the early-start stall again, on its
  third appearance.

## First loaded hour on plugin 0ee61f2f: PASS, no hole (2026-10-11 03:54-04:55 UTC)

Diagnostic owner 0d13ee3c on plugin 0ee61f2f (0001+0002+0003), pinned as in
the two hours before it (IRQs on CPU 1, owner on CPUs 2-3), started 03:53:17
UTC; 3,600 s sixteen-channel soak at 0.1 from 03:54:38 UTC. Evidence
`outputs/latency/dante-confirm-hour-soak-3600s-32f-20261011T035438Z*`.

- **soak: PASS. Longest zero run 1 on every channel in 172.8 million frames
  each, peak 0.1000, no discontinuity.** The owner: `out_holes=0/0
  back_holes=0/0` for the hour, no resync after its first five seconds, no
  re-prime, largest wake gap 1.03 ms.
- The neighbour entry at the end: REACHABLE, last confirmed 0 s ago, in use
  for 3,694 s. `res_failed` did not move in the hour (it had been rising by
  one every eight seconds).
- At the rate of the evening (ten holes in five loaded hours, none of the
  five without one) an hour with no hole would come up by chance about one
  time in seven. With the mechanism shown gone that is strong, and it is
  still one hour.

## Owner 22fd2622 on plugin 0ee61f2f, unpinned: full battery and the loaded hour, all PASS; 472 harness, 660 on the DAW timeline (2026-10-11 04:55-06:12 UTC)

The accepted owner binary on the new plugin (0001+0002+0003), the pinning
taken out (`usb16x16-stall-tuning irqs unpin`, no `OWNER_CPUS`): started
04:55:33 UTC, root, detached. Fresh anchor by gadget restart at 04:56:18 UTC
(audio back in about 1.3 s, no resync; the neighbour entry stayed REACHABLE
through it). Then on that one process, 32 frames. Evidence
`outputs/latency/dante-0ee6-*-20261011T04*`, `T05*`.

| Step (UTC) | Result |
|---|---|
| Noise probe, 04:57 | 0.0 % zeros in 1,244,940 samples, no zero run of 4 or more |
| 800 loaded impulses, 04:57 | 472 (9.833 ms), spread 0; `daw_timeline` 660 (13.750 ms), offset 188 steady |
| 800 loaded impulses, 05:01 | 472, spread 0; 660, steady |
| 800 loaded impulses, 05:04 | 472, spread 0; 660, steady |
| 800 loaded impulses, 05:08 | 472, spread 0; 660, steady |
| **3,600 s soak**, all 16 channels at 0.1, 05:12 | **PASS: longest zero run 1 on every channel, no discontinuity** |

- **The loaded hour is passed, on the configuration that would be the point
  of record, with the battery on the same start and the same fresh anchor.**
  3,200 loaded impulses at 472 samples spread 0; RTL-equivalent 660 samples,
  13.750 ms; 172.8 million frames a channel returned in the hour.
- The owner over the 77 minutes: no resync at all, two links each way
  (start and the gadget restart), no re-prime, no overflow, largest wake gap
  after the relink 1.05 ms. No early-start stall on this start.
- The neighbour entry at the end: REACHABLE, confirmed 0 s ago, in use
  8,347 s (continuously since the plugin first ran at 03:53 UTC, across two
  owner processes). `res_failed` has not moved since then.
- **Two loaded hours on plugin 0ee61f2f now, both without a hole** (pinned
  on the diagnostic owner, unpinned on 22fd2622), after five hours on the
  earlier plugins with one to three holes each. So the pinning is not
  needed, and it is out.
- 472 is inside the band of fresh draws (470 to 507).

Not marked ACCEPTED and not yet the `run-owner.sh` default (which is still
`plugins/xrun-option-retry1`, 5c6b1c0a, a plugin now known to have the
fault): both are the operator's to say. Running on the Pi at the end of this
section: 22fd2622 on 0ee61f2f, this battery's process.

## Persistence: the Dante path as two services, staged (2026-10-11)

The operator chose, for each decision put to him: Dante at boot with the
AES67 unit kept installed as the rollback; root-owned copies under
`/usr/local` with a hash-pinned installer; the owner under its own user with
only real-time priority and memory locking; restart on failure with a limit;
DSP and the web page left as they are for now (both belong to the AES67
bridge; DSP for the Dante owner is the next piece of work, in a new
session); the password-free rule for the hand-run scripts replaced by one
for the units.

`work/dante-mode/service/`:

- `usb16x16-statime.service`: the pinned Statime (e1952224) as root, with
  the measured config, `Conflicts=usb16x16-aes67.service` (the same PTP
  ports), restart always, journal rate-limited.
- `usb16x16-dante.service`: owner 22fd2622 with plugin 0ee61f2f and the
  measured ALSA config, as user `usb16x16-dante` in group `audio` with
  `CAP_SYS_NICE` and `CAP_IPC_LOCK` and nothing else; requires and follows
  the clock unit (a restarted clock restarts the endpoint); no `Requires=`
  on the gadget; three failures in five minutes and it stays down; state in
  `/var/lib/usb16x16-dante`; `--log-every 60` to the journal with Inferno's
  unknown-opcode lines switched off; stopped with SIGINT, pitch controls
  put back afterwards.
- `install-dante-service.sh`: verifies seven sources by hash, stops a
  hand-started owner and Statime, creates the user, installs to
  `/usr/local/libexec/usb16x16-dante/`,
  `/usr/local/lib/usb16x16-dante/alsa-plugins/` and `/etc/usb16x16/dante/`,
  carries the Dante device's saved identity and subscriptions over once,
  replaces `/etc/sudoers.d/usb16x16-dante` with start, stop, restart, enable
  and disable of the two units plus the gadget restart, reloads systemd.
  Enables and starts nothing. `install-dante-service.sh remove` takes it all
  out except the state and the user.

What differs from the accepted conditions and so has to be measured after
the install: the owner not running as root (same binary, same priorities
asked for, through capabilities), its log lines once a minute, the plugin
and binaries read from new paths, the state directory moved. Checks owed in
order: threads at FIFO 79 / 80 / 81 and memory locked; the device back in
Controller with its sixteen subscriptions; the neighbour entry REACHABLE;
noise probe and a loaded run; a Pi reboot coming up on Dante by itself; then
the battery with the loaded hour on the installed form before it is called
ACCEPTED.

Found while staging: `usb16x16-aes67.service` is already disabled on the Pi
(`is-enabled` reads `disabled`), so the notes saying a reboot brings AES67
up are out of date.

## Persistence: installed and running as services; first checks (2026-10-11 07:30-07:45 UTC)

The operator ran `install-dante-service.sh` twice (the second time for the
unit fix below). Installed: owner 22fd2622 and Statime e1952224 in
`/usr/local/libexec/usb16x16-dante/`, plugin 0ee61f2f in
`/usr/local/lib/usb16x16-dante/alsa-plugins/`, the two configs in
`/etc/usb16x16/dante/`, units `usb16x16-statime.service` (01f1bebb) and
`usb16x16-dante.service` (4c27c544), user `usb16x16-dante`, state carried
into `/var/lib/usb16x16-dante/`, `/etc/sudoers.d/usb16x16-dante` replaced.
Both units enabled by the session (`sudo -n systemctl enable`).

- **First start, first unit version: failed once, then ran.** The owner
  started as soon as Statime's socket existed and the plugin gave up with
  `no clock available (timeout waiting for overlay update)`: Statime has no
  clock to give until it has heard the Ferrofish. systemd restarted it 5 s
  later and it ran. Unit 4c27c544 waits until the socket is 8 s old; with it
  the next start came up on the first attempt (`NRestarts=0`).
- **As a service it has what it had as root:** user `usb16x16-dante`,
  effective capabilities `CAP_IPC_LOCK` and `CAP_SYS_NICE` only, no new
  privileges, 414 MB locked, threads at FIFO 79 (loop), 80 (flows RX) and 81
  (flows TX). The Dante device came back as itself with its subscriptions
  (state carried over), the Mac linked at 0.3 s, the neighbour entry
  REACHABLE.
- **Measured on the first service run** (the one that had restarted once;
  aged anchor): noise probe 0.0 % zeros; 800 loaded impulses 473 spread 0,
  `daw_timeline` 661 (13.771 ms), offset steady. Evidence
  `outputs/latency/dante-svc-*-20261011T0732*`. That run also had the
  early-start event again at 14.3 s (`tx lag of 122 samples`, one resync of
  157 frames, a relink): fourth appearance, this time 25 s after Statime
  itself had started.
- Stopping the unit ends the owner cleanly (SIGINT, `exit=0`, summary
  lines in the journal).
- `measure-candidate.sh` reads the endpoint's log from the journal when the
  service is active.

Not yet done: the reboot (a `sudo reboot` over ssh from the session was
refused by the session's own safety layer, so it is the operator's to do or
allow), then the battery with the loaded hour on the installed form.

Also staged at the operator's request, not installed: `usb16x16-dante-candidate`
(252c07d8) and `install-dante-candidate-launcher.sh` (aa320ba1). The
launcher runs a candidate owner build from `~/usb-16x16-work/dante-mode/owner/`
as the service user with the same two capabilities, through `systemd-run`,
from root-owned copies in `/run/usb16x16-dante-candidate/`; a password-free
rule for that one script lets a session try builds unaided without anything
it runs having root. It refuses while the service is active.

## The installed services: reboot, then battery and the loaded hour on a fresh anchor, all PASS; 465 harness, 653 on the DAW timeline (2026-10-11 07:46-09:05 UTC)

**Reboot** (the operator's `sudo reboot`; up at 07:46:43 UTC). Unaided:
`usb16x16-statime` active at 07:47:01, `usb16x16-dante` at 07:47:09 on its
first attempt (`NRestarts=0`), the Mac linked 0.4 s into the owner, threads
at FIFO 79 / 80 / 81, 414 MB locked, capabilities `CAP_IPC_LOCK` and
`CAP_SYS_NICE` only, the neighbour entry REACHABLE, `usb16x16-aes67`
inactive, the gadget and the governor units active.

**Battery on the installed form.** One short service stop and start for the
launcher trial (below), then a fresh anchor by `systemctl restart
usb-16x16.service` at 07:49:09 UTC under the running service (gone and back,
relinked, no resync), then on that one process at 32 frames. Evidence
`outputs/latency/dante-service-*-20261011T07*`, `T08*`.

| Step (UTC) | Result |
|---|---|
| Noise probe, 07:49 | 0.0 % zeros in 1,244,947 samples, no zero run of 4 or more |
| 800 loaded impulses, 07:50 | 465 (9.688 ms), spread 0; `daw_timeline` 653 (13.604 ms), offset 188 steady |
| 800 loaded impulses, 07:53 | 465, spread 0; 653, steady |
| 800 loaded impulses, 07:57 | 465, spread 0; 653, steady |
| 800 loaded impulses, 08:00 | 465, spread 0; 653, steady |
| **3,600 s soak**, all 16 channels at 0.1, 08:04 | **PASS: longest zero run 1 on every channel, no discontinuity** |

- **The installed form passes what the accepted pair passed by hand:** 3,200
  loaded impulses at 465 spread 0, RTL-equivalent 653 samples (13.604 ms), a
  loaded hour with no hole.
- The service over the 76 minutes, from its journal: no resync, two links
  each way (start and the gadget restart), no re-prime, no overflow, largest
  wake gap 1.04 ms, no restart. No early-start event on this start.
- The neighbour entry REACHABLE throughout; `res_failed` since boot: 1.
- **Three loaded hours on plugin 0ee61f2f now without a hole.**
- 465 is 5 below the lowest earlier fresh draw: the band of fresh draws is
  now 465 to 507 (RTL 653 to 695, 13.6 to 14.5 ms).

**The candidate launcher**, installed by the operator at 07:47 UTC
(252c07d8). Tried once: it refused correctly with the service active and
for a binary outside the owner directory, and then refused wrongly, taking
its own process for a running owner (`pgrep -x` sees 15 characters of a
name and the launcher's begins with the owner's). Fixed in 8b4b5d92
(installer 4d601131), staged; the operator's reinstall and a proper trial
are owed.

Not marked ACCEPTED in the installed form: the operator's to say.

## ACCEPTED 2026-10-11: the installed services are the point of record

Accepted by the operator after the reboot test and the 07:49-09:05 UTC
battery and loaded hour. Point of record for the Dante path: **the two
services as installed, `usb16x16-statime.service` (01f1bebb, Statime
e1952224) and `usb16x16-dante.service` (4c27c544: owner 22fd2622, plugin
0ee61f2f, user `usb16x16-dante` with `CAP_SYS_NICE` and `CAP_IPC_LOCK`),
enabled at boot; harness 465 samples (9.688 ms), `daw_timeline` 653
(13.604 ms) at 32 frames on the battery's anchor.** Lead 128, return queue
144, Inferno 2 ms, no pinning. Fresh draws span 465 to 507: RTL-at-32 about
14.1 ms plus or minus 0.45. AES67 record for scale: 703 / 891 (18.563 ms).

Covered: a cold boot coming up unaided; noise probe, 4 x 800 loaded
impulses and a 3,600 s sixteen-channel soak on one start and one fresh
anchor; bit transparency for every code a Mac can send (the same owner
code, the evening before); the host-stop, gadget-restart and cable-pull
fault paths (by hand, before the install). Not covered: Mac sleep, a
Controller restart, an Ethernet reconnect under the service; DSP (none on
this path yet); the web page (it reads the AES67 service).

Carried open: the early-start loop gap (four appearances, none on the three
service starts since the unit fix). Rollbacks as in the INSTALLED entry.

**The candidate launcher** needed a second fix: 8b4b5d92 still refused,
because the subshell that runs its `pgrep` carries the launcher's name too.
8afe885c finds a running owner by what the process executes
(`/proc/*/exe`), not by name. Staged with installer b50395ca; on the Pi the
installed copy is still 8b4b5d92, which refuses every start. Never yet run
to the point of starting an owner: the first job of the session that needs
it is to have the operator reinstall it and to try it with the accepted
binary.

## DSP in the owner, first step: `--dsp-preset` on the outgoing direction, built and run with no signal (2026-10-11 13:00-13:11 UTC)

**The launcher first.** e20b9874, reinstalled by the operator, started the
accepted owner 22fd2622 at 13:00:14 UTC as `usb16x16-dante` with the two
capabilities, locked memory and FIFO 79 / 80 / 81, and stopped it cleanly.
Nothing is owed on the launcher; `PLUGIN_DIR=`, `CONFIG=` and `CPUS=` are
untried.

**What was added.** `owner/dsp_path.hpp` (`OutDsp`): the bridge core's
`DspStage` behind an integer boundary. With `--dsp-preset FILE` each block
the outgoing direction (gadget capture to Dante) is about to hand to Inferno
goes S32 -> float -> `DspStage::process` -> 24-bit -> S32, with the core's
`s32_to_float` (exact for a 24-bit value) and `float_to_s24` (round to
nearest, saturating). The stage is reset at each prime and runs on the prime
block and every block after it; discarded blocks (idle, armed) are not
filtered. The preset is loaded before anything is opened and a preset that
does not load is a refusal (exit 2), never a direct run. Without the option
no sample is converted and the path is the integer copy it was. Nothing on
the return direction; no new thread. A `DSP` line follows the `USB` line
when the stage has run: `dsp_us_max`, `dsp_us_mean` (conversions included),
calls, resets.

The owner now links the bridge core: one more source file on the build line
(`main.cpp`'s header). On the Pi the core is staged at
`~/usb-16x16-work/phase4-bridge/` and the candidate's source at
`~/usb-16x16-work/dante-mode/owner/dsp/`; `owner/main.cpp` there is still
the accepted e53c8407.

**The base is the diagnostic source, not the accepted one.** The repo's
`main.cpp` was 7aa12be8 (the hole counters, binary 0d13ee3c, which has a
loaded hour of its own); the accepted 22fd2622 is e53c8407, 42 lines
earlier. The candidate therefore differs from the record by the hole
counters as well as the stage, and its direct run is the control for both.

```
fbff2269  owner/usb16x16-dante-owner-dsp   (binary, Pi only)
8b2b8cf4  owner/main.cpp
82dea738  owner/dsp_path.hpp
5237452b  owner/dsp_path_test.cpp
01dd07e9  phase4-bridge/src/bridge_core.cpp      (as in bridge 7e8f1064's tree)
1443dc03  phase4-bridge/include/usb16x16/bridge_core.hpp
```

**Tested off the audio path** (`dsp_path_test.cpp`, Mac and Pi, all passed):
unloaded is inert; a unity artifact returns every 24-bit code unchanged,
extremes included, at block sizes 1 to 1024; a gain rounds to nearest, keeps
the low byte zero and saturates rather than wraps past either full scale;
reset empties a delay line; a block longer than the scratch is left alone.
The four artifacts in `/etc/usb16x16/dsp/` load.

**Three runs through the launcher, the Mac holding the device open and
sending silence** (service stopped 13:06:50 to 13:10:26 UTC):

| Run | Preset | Biquads | `dsp_us_mean` | `dsp_us_max` | `gap_us_max` | Depth found | Faults |
|---|---|---|---|---|---|---|---|
| direct, 34 s | none | 0 | no line | no line | 1009-1018 | 78-81 | none |
| transparent, 64 s | `transparent.dsp` ad695984 | 256 | 66.0 | 73.8 | 1014-1076 | 76-80 | none |
| loaded, 64 s | `loaded.dsp` 2b6baa04 | 308 | 79.5 | 91.4 | 1008-1089 | 75-81 | none |

Each linked both ways in 0.3 s with one prime, one stage reset, no resync,
re-prime, overflow or PCM fault, and the mean outgoing depth after the write
stayed at 128. The depth as found sits 2 to 4 frames lower with a preset:
the write lands 70 to 90 us later in the wake, at the same pointer, so this
is slack spent, not latency added. A file that is not an artifact was
refused with exit 2 and the launcher reported it. Logs
`/dev/shm/dante-owner-20261011T13{0735,0811,0917}Z.log` on the Pi (tmpfs).

**What this does not show.** Every sample was zero. No filter has carried
audio through the owner, the cost is the cost of filtering silence (the
bridge's figure for a comparable preset with audio was about 130 us), and
no latency figure was taken. Runs were a minute.

**Owed, in order.** (1) Direct on the candidate against the record: noise
probe and an impulse run on a fresh anchor, to show the new build reads as
22fd2622 does. (2) The same with `transparent.dsp`, then `bitexact` through
it (full-scale noise on sixteen outputs: monitors muted, the operator's go).
(3) `loaded.dsp` under load for `dsp_us_max` with audio, then the battery
and the 3,600 s soak before any ACCEPTED. (4) Live coefficients: the control
thread polling a live file, created with the telemetry and steward threads
before the device is opened (rule 3), `publish()` as in the bridge. (5) The
meter tap. (6) A service form: the unit's command line carries the preset,
and an applier the web page can drive; the page still reads the AES67
service's state.

The service is active again since 13:10:26 UTC (22fd2622, aged anchor, no
figure known for this start).

## DSP candidate fbff2269 with signal: direct, transparent, unity and loaded, short runs (2026-10-11 13:17-13:37 UTC)

Outputs muted by the operator. Candidate through the launcher, Mac harness
at 32 frames; `measure-candidate.sh` now counts a launcher candidate as an
endpoint (it runs as `owner`, which the name test did not see). Each of the
first two arms had its own gadget restart, so its own anchor.

| Arm | Preset | Noise probe | 800 loaded impulses | `daw_timeline` | `dsp_us` mean / max | Loop gap max |
|---|---|---|---|---|---|---|
| direct | none | clean | 497, spread 0 | 685 (14.271 ms) | no stage | 1.04 ms |
| transparent | `transparent.dsp`, 256 biquads | clean | 471, spread 0 | 659 (13.729 ms) | 81 / 258 us | 1.11 ms after the restart |

Both levels are inside the band of fresh draws on the record (465 to 507),
offset 188 steady, no discontinuity. Two anchors cannot say the stage adds
nothing to the level, only that it adds nothing the draw does not cover; the
preset has no delay and the block is written at the same pointer.

**Bit transparency through the stage: PASS.** With
`config/dsp-unity.dsp` (ae58e86f: sixteen straight channels at gain 1, no
biquads) every sample goes through float and back, and
`usb16x16-latency bitexact` at 32 frames read 120 s, 5,760,000 frames, pass,
largest code 8388590, no discontinuity
(`outputs/latency/dante-dsp-unity-bitexact-32f-20261011T132823Z.json`). The
conversion alone costs 12 us a block. This was also the first use of the
launcher's copying of a file option from the operator's tree.
`transparent.dsp` is not a candidate for this test and was never meant to
be: its bands are +/-0.01 dB bells, transparent to an impulse, not to a bit
(the return peak read 2097414 against 2097148 sent).

**The loaded preset with audio.** `loaded.dsp` (308 biquads), sixteen
channels at 0.1 for 180 s: `dsp_us_mean` 92 to 97, `dsp_us_max` 169, loop
gap at most 1.13 ms, depth held at 128, no resync, re-prime, overflow or
fault. A second start, 2 x 60 s: the same, longest zero run 1 on all
sixteen return channels.

**Seen on the way, none of it the stage's.**
- The gadget restart under the transparent arm cost one 32-frame playback
  resync and a 3.3 ms loop gap at the moment the gadget went away; under the
  direct arm the same restart cost neither. One each: not a comparison.
- `back_holes` counted 145 on the transparent arm and `out_holes` none. They
  came only while the harness sent bare impulses (the readiness probes), and
  are the filters' tails crossing zero at 24 bits, not gaps: the counter
  reads the return after the stage and means nothing for an impulse through
  filters. Under noise and under load it stayed still. The direct arm
  counted one hole of 52 frames on both streams, so sent by the Mac.
- A capture begun 12 s after an owner start had return channels 3 to 10
  silent for up to 5.8 s (the first 180 s loaded run); begun 45 s after, none.
  Some return channels take about 18 s to come back after an owner start.
  The wrapper's readiness probes watch channel 1 only: leave 30 s after a
  start before a sixteen-channel capture.

**Where this leaves the candidate.** Steps 1 to 3 of the owed list are done
in their short form. Not done: four runs per arm, a ten-minute or one-hour
soak, any run on the accepted (non-diagnostic) base. Those belong to the
build that is meant to be accepted, which still lacks live coefficients,
the meter tap and a service form.

Service active again at 13:37 UTC (22fd2622, aged anchor).

## Live coefficients in the owner, and a capture fault that never recovered, found and fixed (2026-10-11 13:47-13:54 UTC)

**What was added.** `owner/dsp_live.hpp` (`DspLive`): the bridge's live
control thread (`work/phase4-bridge/LIVE_COEFFICIENTS_DESIGN.md`, step 3) as
an object with a `poll()`, same file protocol and the same `DSPLIVE` status
line, so what writes a live file for the bridge writes one for the owner.
`--dsp-live-file PATH` (and `--dsp-live-status`, default the file with
`.status`) starts a thread that polls the file every 50 ms, loads a changed
file and publishes its numbers into the running stage; another shape or a
malformed file is refused and changes nothing; a file older than the process
is ignored. The thread is made with the telemetry and steward threads,
before the device is opened and before the loop turns real-time (rule 3), at
normal priority: eight threads instead of seven. `DSPLIVE applied|refused|
ignored` lines in the log, `dsp_live_gen`, `dsp_live_applied`,
`dsp_live_refused` on the `DSP` line.

One difference from the bridge. Its stage runs on every wake; the owner's
runs only while a host is sending, and a publish waits until the loop has
taken the one before. So on every wake that filters nothing the loop calls
`OutDsp::take()`, two atomic loads, or a second update would wait for audio.

Tested off the audio path (`dsp_live_test.cpp`, Mac and Pi, against real
files): applied on the poll that finds the file, an unchanged file not read
again, a third update held while the second is untaken and let through by
`take()`, another shape and a malformed file refused with nothing changed, a
stale file ignored, an unwritable status file counted and not fatal.

```
8e0513fa  owner/usb16x16-dante-owner-dsplive   (binary, Pi only; a62cc882 was the build before the fix below)
78a997f8  owner/main.cpp
5a5a044e  owner/dsp_live.hpp
b2cfcfc4  owner/dsp_path.hpp
ce6745e0  owner/dsp_live_test.cpp
7fd7f047  config/dsp-unity-half.dsp            (dsp-unity at gain 0.5, same shape)
```

**FOUND: after a gadget capture overrun the outgoing direction never came
back. In the accepted owner too.** On the first live build (a62cc882) the
loop stalled once for 15.6 ms, 27.6 s after its start (cause below). Both
gadget PCMs overran (-32). The return direction re-primed and flowed again;
the outgoing one stayed idle with `capture_faults` rising 20 a second, 2,500
in two minutes, the gadget capture in XRUN, the Mac sending throughout and a
sixteen-channel capture reading silence for 68 s. `capture_fault` dropped,
prepared and started the capture at once and then left it unread for the
50-wake holdoff: 50 ms against a 480-frame buffer, so it overran inside the
holdoff and faulted at the first read, every time. The code is unchanged
since before 22fd2622, so the installed service has it: with a host sending,
any loop stall longer than the capture buffer's slack ends the outgoing
audio until the owner or the gadget is restarted. It had not been seen
because no capture fault had occurred with a host sending (the host-stop and
gadget-restart paths leave by other doors).

Fix (in 8e0513fa): the capture is dropped at the fault and prepared and
started when the holdoff ends, so it is read from the wake it starts on; a
gadget that has gone (-19) is still handed back at once.

**Shown with an injected stall.** `--stall-at SECONDS --stall-ms MS` (test
only) stalls the loop once. 8e0513fa, `dsp-unity.dsp`, sixteen channels at
0.1 from the Mac, 20 ms at 60 s:

| | |
|---|---|
| Loop gap | 20.0 ms |
| Inferno playback | one resync, 833 frames |
| Gadget | one capture fault, one playback fault |
| Both directions flowing again | 100 ms after the stall (the holdoff), `tx_links` 2, stage reset |
| Mac capture | one zero run of 3,726 frames (77.6 ms) on all sixteen channels, no other |

**Live updates under audio, same run.** Return peak against sent peak
838,857:

| Time | Written to the live file | Outcome | Return peak |
|---|---|---|---|
| 73.0 s | `dsp-unity-half.dsp` | applied | 419,428 |
| 87.2 s | `dsp-unity.dsp` | applied | 838,857 |
| 96.5 s | `transparent.dsp` | refused, shape differs | unchanged |
| 101.7 s, 102.0 s | half, then unity 0.3 s later | both applied | 838,857 |

`dsp_live_gen` 4, applied 4, refused 1, no status write failed; loop gap
1.02 ms at most across every publish, `dsp_us_max` unmoved, no resync or
fault after the injected one. A stray file (`.bashrc`) was refused with the
loader's reason on the earlier run.

**Not explained: the 15.6 ms stall itself.** One occurrence, 13:48:01 UTC,
with nothing of this session running on the Pi at that second (the launcher
had staged the binary 28 s earlier and the build had finished about 40 s
earlier; `dirty_expire_centisecs` is 3000, so a write-back of those to the
SD card is a candidate, not a finding). It is the same family as the open
early-start loop gap. The run after it had none in 140 s apart from the
injected one, and a 1.96 ms gap at the moment the harness opened the device.

**Not done.** No latency figure, noise probe or soak on 8e0513fa. The
`take()` path has run on the Mac only: on the Pi the Mac held the device
open and the outgoing direction never went idle. The status and live files
were in `/dev/shm` for the trial; a service form needs a directory the
service user can write and the applier can reach.

**Owed.** (1) The operator's decision on the capture-fault fix for the
installed service: it is a fault-path change to the accepted owner and can
be built on the accepted source alone (e53c8407 plus the fix) if it is to go
in ahead of DSP. (2) Battery on the candidate: noise, 4 x 800, the hour.
(3) The meter tap. (4) The service form and the applier.

Service active again at 13:53:37 UTC (22fd2622, aged anchor).

## The capture-fault fix on the accepted source: owner e392dd71, battery and the loaded hour PASS, 465 / 653; staged for install (2026-10-11 14:10-15:29 UTC)

At the operator's word ("let's apply the fix"). **e392dd71** is the accepted
owner's source (e53c8407, binary 22fd2622) with two changes and nothing
else, no DSP and no hole counters: the capture-fault fix of the section
above, and the test-only `--stall-at` / `--stall-ms`, kept in so that the
fix can be shown on the binary that is installed. Source 437b14fd; the diff
is `service/owner-capture-fault.patch` (2e1638d1). Built on the Pi with the
service stopped, the accepted one-line build, as
`owner/usb16x16-dante-owner-fix`; `owner/fix/` holds its source there. All
runs through the launcher, as the service user, plugin 0ee61f2f.

**The fix, on this binary.** `--stall-at 60 --stall-ms 20` under sixteen
channels at 0.1: loop gap 20.0 ms, one 833-frame playback resync, one
capture fault and one playback fault, both directions flowing again 100 ms
later (`tx_links` 2), one zero run of 3,714 frames (77.4 ms) on all sixteen
channels at the Mac and no other
(`outputs/latency/dante-fix-stall-continuous-60s-32f-20261011T141144Z.json`).
On 22fd2622 the same fault ended the outgoing audio.

**Battery on one start and one fresh anchor** (started 14:12:59 UTC without
the stall option, gadget restart 14:13:04, label `dante-fix`):

| Check | Result |
|---|---|
| Noise probe at 32 | clean, no zero run of 4 or more |
| 4 x 800 loaded impulses at 32 | 465 samples (9.688 ms) every run, spread 0 |
| `daw_timeline` | 653 (13.604 ms), offset 188 steady |
| 3,600 s sixteen-channel soak | PASS, longest zero run 1, no discontinuity |
| Owner over 4,577 s | no resync, re-prime, overflow or capture fault; loop gap at most 1.05 ms; one link each way after the gadget restart |
| Ferrofish neighbour entry | REACHABLE at the end |

The same 465 / 653 as the record's battery. The gadget restart under this
start took the -19 path as before (one playback fault, one detach, no
capture fault, no resync).

**Staged on the Pi, not installed:**
`service/install-owner-update.sh` (77c30e05) replaces the installed owner
binary and nothing else: it checks the new binary is e392dd71 and the
installed one is 22fd2622, stops `usb16x16-dante.service`, keeps the old
binary as `usb16x16-dante-owner.previous`, and starts the service;
`rollback` puts the old one back. `install-dante-service.sh` is repinned to
e392dd71 for a full reinstall (d50c44ac, was 798ff158). Operator:

```
sudo ~/usb-16x16-work/dante-mode/service/install-owner-update.sh
```

Not covered: the fix has been exercised by an injected 20 ms stall, twice
(here and on the DSP candidate), not by a stall that arose by itself; a
longer stall, or one that also detaches the gadget, is untried. Service
active on 22fd2622 since 15:29:18 UTC (stopped from 14:10:30 for the build
and the battery; aged anchor).

## ACCEPTED 2026-10-11: owner e392dd71 installed and accepted (16:13 UTC)

Installed by the operator's `sudo install-owner-update.sh` at 16:13:30 UTC,
22fd2622 kept as `usb16x16-dante-owner.previous`. On the installed form,
fresh anchor 16:14:04 UTC: noise probe clean, 800 loaded impulses all 466
(9.708 ms) spread 0, `daw_timeline` 654 (13.625 ms), offset 188 steady; the
two capabilities, locked memory, FIFO 79 / 80 / 81, neighbour entry
REACHABLE. Accepted by the operator on that and on the launcher battery of
the section above (465 / 653, the loaded hour).

## The meter tap in the owner: built, tried under audio (2026-10-11 16:46-16:50 UTC)

**What was added.** `owner/meter_tap.hpp`: the bridge core's `LevelMeter`
on three points, and a publisher that writes them in the bridge's file
format (`METERS v=1`, one `TAP` line per stage, 50 ms windows), from a
thread made before the device is opened like the others. `--meter-file
PATH`, with or without a preset.

| Tap | What it sees |
|---|---|
| `usb-capture` | what the host sent, before the stage |
| `dante-playback` | what goes to Dante, after the stage; its clip count is of the floats before the converter saturates them |
| `dante-capture` | what Dante returned; it goes to the host unchanged, so there is no fourth tap |

The outgoing taps see the blocks that go out, so they stand still while the
outgoing direction is idle or priming. With a preset the taps read the
stage's own float block before and after the filters (`OutDsp` now exposes
its three steps); without one a block is converted for the meters only and
the integer path is untouched. `atomic_file.hpp` is the write-by-rename both
publishers share. A `METER` line follows the `DSP` line: `meter_us_max`,
`meter_us_mean`, calls (two a wake: the outgoing pair, the return).

```
62879558  owner/usb16x16-dante-owner-dspmeter   (binary, Pi only: preset, live, meters, the capture-fault fix, --stall-at)
bd7bb957  owner/main.cpp
fd0a3714  owner/meter_tap.hpp
3776245d  owner/dsp_path.hpp
506ed603  owner/dsp_live.hpp
01cacef1  owner/atomic_file.hpp
```

Tested off the audio path (`meter_tap_test.cpp`, Mac and Pi): half and
quarter scale read -6.0 and -12.0 dBFS peak and RMS, a window is written
once and only when closed, the return tap publishes on its own, through a
+12 dB stage the output tap reads +6.0 / 0.0 and counts every clamped
sample while the input tap counts none, an unwritable file is counted and
not fatal. The other two owner tests still pass.

**Under sixteen channels at 0.1 from the Mac, through the launcher:**

| Run | Meter file | `meter_us` mean / max | `dsp_us` mean / max | Loop gap max |
|---|---|---|---|---|
| direct, meters | all three taps -20.0 dBFS on sixteen channels | 4.4 / 9.5 us | no stage | 1.04 ms |
| `loaded.dsp`, meters, live following | `usb-capture` -20.0; `dante-playback` -26.8 to -56.3 by channel; `dante-capture` the same to 0.1 dB except channel 13 (-56.3 sent, -60.3 back, in different 50 ms windows) | 3.8 / 6.0 us | 77.9 / 88.3 us in the lines read, which follow the audio; not read during it | 1.19 ms |

About twenty writes a second, none failed; one prime, no resync or fault
either run; a same-shape live file applied under the meters. Files in
`/dev/shm` for the trial.

**Not done at that point:** the battery (next section) and a service form.

## DSP candidate 62879558: battery and the loaded hour PASS with a preset, meters and live following, 493 / 681 (2026-10-11 16:50-18:07 UTC)

Through the launcher: `--dsp-preset /etc/usb16x16/dsp/transparent.dsp
--meter-file --dsp-live-file` (256 biquads; meter and live files in
`/dev/shm`, no live file written), plugin 0ee61f2f. One start (16:50:33
UTC), one fresh anchor (gadget restart 16:50:38), label
`dante-dsp-transparent`.

| Check | Result |
|---|---|
| Noise probe at 32 | clean, no zero run of 4 or more |
| 4 x 800 loaded impulses at 32 | 493 samples (10.271 ms) every run, spread 0 |
| `daw_timeline` | 681 (14.188 ms), offset 188 steady |
| 3,600 s sixteen-channel soak | PASS, longest zero run 1, no discontinuity |
| Stage cost over 76 minutes | `dsp_us_mean` about 65 over the whole run (idle stretches included), `dsp_us_max` 134 |
| Meter cost | `meter_us_max` 46; 132,880 meter files written, none failed |
| Owner | one link each way after the gadget restart, no re-prime, overflow or capture fault; loop gap at most 1.10 ms apart from the gadget restart |
| Ferrofish neighbour entry | REACHABLE at the end |

493 is inside the band of fresh draws (465 to 507); the accepted owner drew
465 and 466 on its two anchors today, so this says the stage adds nothing
the draw does not cover, not that it adds nothing. A like-for-like figure
needs the two builds on one anchor, which a restart of either does not
give.

**A gadget restart costs a 3 to 4 ms loop gap and a small resync about one
time in three, on every build including the accepted one.** The restart
under this battery cost one 23-frame playback resync and a 3.15 ms loop gap
at the moment the gadget went away, as the transparent arm did at 13:22 UTC
(32 frames, 3.3 ms). Counted afterwards, six restarts each with the Mac
holding the device open:

| Owner | Arguments | Resyncs in 6 restarts | Loop gap at those |
|---|---|---|---|
| 62879558 | transparent, meters, live | 1 (23 frames) | 3.15 ms |
| 62879558 | no preset, meters | 4 (34 to 47 frames) | 3.4 to 3.7 ms |
| 62879558 | transparent only | 2 (56, 66 frames) | 3.8, 4.0 ms |
| e392dd71, the installed service | as installed | 2 (39, 41 frames) | 3.5 ms both |

So it is not the stage, the meters or the live thread; it belongs to the
gadget going away under a running owner (the loop is held for 3 to 4 ms and
the Inferno pointer is forwarded by the frames it lost). Every restart
re-linked both directions with no capture fault. A gadget restart is an
outage of about a second anyway; this adds a 1 ms hole on the Dante side of
it. Not pursued.

**Not covered on 62879558:** `loaded.dsp` for an hour; a live file written
during the soak; the direct arm's own four runs; the `take()` path on the
Pi; any service form.

## The service form with DSP: wrapper, unit and installer staged (2026-10-11, about 18:45 UTC)

To the operator's choices: the service runs direct with the meters on at
boot, a preset and live following only once one is applied; the unit takes
its options from a configuration file; and the DSP owner is installed once,
together with this form, not ahead of it.

| File (`work/dante-mode/service/`) | Hash | What it is |
|---|---|---|
| `usb16x16-dante-start` | 1f83825b | the unit's `ExecStart`: reads `/etc/usb16x16/dante/owner.conf` (KEY=value, read, never sourced: `METERS`, `DSP_PRESET`, `DSP_SHA256`, `DSP_LIVE`), builds the owner's command line and execs it |
| `usb16x16-dante-dsp.service` | 9f5289dd | the unit, installed as `usb16x16-dante.service`: as 4c27c544 with the wrapper as `ExecStart`, `RuntimeDirectory=usb16x16-dante` (meter file, live file, live status in `/run/usb16x16-dante/`) and `RestartPreventExitStatus=2` |
| `owner.conf.default` | cb022708 | `METERS=1` and nothing else |
| `install-dante-dsp.sh` | 6b5683f6 | swaps owner (e392dd71 to 62879558), wrapper and unit; installs the configuration only if there is none; keeps the replaced owner and unit in `before-dsp/`; starts the service and, if it is not up with both Inferno streams running within 30 s, puts the previous owner and unit back and starts those; `rollback` does the same by hand |
| `test-dante-start.sh` | | the wrapper's test, Mac and Pi: all passed |

The wrapper's rules: with no configuration file the command line is the old
unit's, to the argument; a preset must be a `.dsp` file directly under
`/etc/usb16x16/dsp/` and hash to `DSP_SHA256`; `DSP_LIVE=1` needs a preset;
anything it cannot honour is a refusal with exit 2, which the unit does not
restart on. A system configured with crossovers does not come up without
them; the cost is no Dante audio until the configuration is mended.

Checked without root on the Pi: hashes as above, the wrapper's test, its
`--print` with no file (the old command line) and with the default
(`... --log-every 60 --meter-file /run/usb16x16-dante/meters.txt`),
`systemd-analyze verify` on the unit (its one complaint is the wrapper not
being installed yet). **Not exercised: the unit itself, the wrapper as the
service user, the installer.** Those run for the first time at the
operator's install; the installer's own rollback is the guard.

Operator:

```
sudo ~/usb-16x16-work/dante-mode/service/install-dante-dsp.sh
```

After it: check the installed form (capabilities, priorities, the meter file
in `/run/usb16x16-dante/`), then the battery on a fresh anchor in the boot
configuration, direct with meters, which this binary has not had: noise,
4 x 800, the hour. `install-dante-service.sh` (the from-nothing installer)
still describes the service before DSP and is to be brought up to date once
this form is accepted. Still to build: the applier's Dante backend and the
page.

## The DSP service installed: battery and the loaded hour PASS in the boot configuration, 465 / 653 (2026-10-11 18:58-20:15 UTC)

Installed by the operator's `sudo install-dante-dsp.sh` at 18:58:25 UTC; it
came up first time and the installer's rollback was not used. On the
installed form: owner 62879558 started by `usb16x16-dante-start` (1f83825b)
under unit 9f5289dd, command line the old one plus `--meter-file
/run/usb16x16-dante/meters.txt` (`owner.conf` is `METERS=1`), user
`usb16x16-dante` with the two capabilities only, memory locked, threads
FIFO 79 / 80 / 81 and the meter publisher at normal priority, the meter
file written by the service user, the neighbour entry REACHABLE. Replaced
owner e392dd71 and unit 4c27c544 kept in
`/usr/local/libexec/usb16x16-dante/before-dsp/`.

**Battery on the installed service, direct with meters, one start and one
fresh anchor** (gadget restart 18:58:49 UTC under the running service,
label `dante-dsp-service-direct`):

| Check | Result |
|---|---|
| Noise probe at 32 | clean, no zero run of 4 or more |
| 4 x 800 loaded impulses at 32 | 465 samples (9.688 ms) every run, spread 0 |
| `daw_timeline` | 653 (13.604 ms), offset 188 steady |
| 3,600 s sixteen-channel soak | PASS, longest zero run 1, no discontinuity |
| Service over 76 minutes | no restart, no re-prime, overflow or capture fault; loop gap at most 1.05 ms apart from the gadget restart |
| Meters | 134,035 files written; `meter_us_max` 67 |
| Ferrofish neighbour entry | REACHABLE at the end |

The same 465 / 653 as e392dd71's battery and the first accepted record's.
The gadget restart that drew the anchor cost a 40-frame resync and a 3.5 ms
loop gap, the one-in-three behaviour of the section before last.

**Not covered in service:** a preset or a live update through the service
form (the preset arm's hour was through the launcher, on this binary); the
wrapper's refusals under the unit (tested as a script only); a reboot on
this form; the applier and the page, which do not exist for Dante yet.

## The applier's Dante backend: written, tested, staged (2026-10-11, about 21:00 UTC)

`work/web-control/usb16x16-apply` 1.4.0 (e453d50f) serves whichever stack is
installed: `DanteApplier` when `usb16x16-dante.service` is the unit enabled
at boot (or `USB16X16_STACK=dante`), the AES67 `Applier` otherwise. The
AES67 class is untouched apart from one word in three messages; its 43 tests
pass unchanged.

For Dante there is no supervisor and no profile table. A profile is
`direct` or `dante-<slug>`, the latter being a file
`/etc/usb16x16/dsp/dante-<slug>.dsp` installed by a `preset` request; the
prefix keeps a Dante `remove` from ever taking a file an AES67 block pins.

| Request | What it does on the Dante stack |
|---|---|
| `profile` | rewrites `/etc/usb16x16/dante/owner.conf` (`METERS` kept; a preset gets its path, hash and `DSP_LIVE=1`), having `usb16x16-dante-start --print` accept the new text on a copy first; stop, write, start; verify; on failure the previous file goes back by the same steps |
| `preset` | the bridge's guards (bounds, every section stable, gains sane, at most 308 biquads), the load check through `usb16x16-dsp-offline`, install as `dante-<slug>.dsp`, then the switch; re-applying the live slug restarts onto the new file |
| `remove` | deletes an installed preset that is not live |
| `live`, `commit` | the bridge's, against `/run/usb16x16-dante/dsp-live.dsp` and its status; commit rewrites the installed file and the pin in `owner.conf`, no restart |
| `shutdown` | stops the Dante unit, leaves the receipt, powers off |

Verification of a start: the unit active on one invocation, no `FATAL`,
`NETERROR` or wrapper refusal in that invocation's journal, the `DSP loaded
file=` line the profile calls for (or none), `DSPLIVE following` with a
preset, `NETSTART capture=RUNNING playback=RUNNING`, then a 15 s settle on
the same checks. A host is not required to be streaming.

`test_dante_apply.py`, 27 tests, with systemd and the owner scripted and
the configuration checked by the real `usb16x16-dante-start`: switches both
ways, refusals that change nothing, rollback on a failed start, on a fatal
line, on a restart by itself and on streams that never start, a rollback
that also fails, a file changed between validation and the switch, preset
install and replacement, the cap, remove, live, revert, commit (and that
the committed pair is one the wrapper starts), an owner that does not
answer or refuses, shutdown. All 90 web-control tests pass.

Staged on the Pi in `~/usb-16x16-work/web-control/` with
`install-web-control.sh` repinned (07e9cb61). Read-only there: the staged
program detects `dante`, reads `direct` as live, lists `direct`, unit
active. **Not installed** (`/usr/local/bin/usb16x16-apply` is still
e6e7e844, which knows only AES67 and would refuse every request now, the
AES67 service being disabled). **Never run as root against the real unit.**

The 308-biquad ceiling is the bridge's. On the owner an hour has been run
at 256 (`transparent.dsp`); 308 (`loaded.dsp`) has had about five minutes
with audio at 95 us mean, 172 max. An hour at 308 is owed before the
ceiling is called proven here.

Operator: `sudo ~/usb-16x16-work/web-control/install-web-control.sh`
(installs the applier; the web service and units are unchanged, hashes
equal). Then, with his go, a trial by request files in the spool: a preset,
a live update, a commit, back to direct. The page itself still speaks to
the AES67 service: `usb16x16-web` is the next piece.

## The applier on the installed Dante service: a full trial through the spool (2026-10-11 22:04-22:07 UTC)

`usb16x16-apply` e453d50f installed by the operator
(`install-web-control.sh` 07e9cb61). With his go, requests were written to
`~/usb-16x16-work/web-apply/request.json` as the web service writes them,
the path unit ran the applier as root, and each receipt was read back.
Sixteen channels at 0.1 from the Mac during the live steps; the meter file
gives the levels (channels 1 and 2 shown, all sixteen alike).

| Request | Outcome | Seen on the Pi |
|---|---|---|
| `preset` `trial`, `dsp-unity.dsp`, expecting `direct` | done: validating, checking, installing, stopping, switching, starting, verifying, settling | `/etc/usb16x16/dsp/dante-trial.dsp` root-owned; `owner.conf` with path, hash, `DSP_LIVE=1`; owner restarted with `--dsp-preset`, the live file and its status; `DSP loaded`, `DSPLIVE following`, both streams running, linked in 0.3 s |
| `live`, `dsp-unity-half.dsp` | done, applied | meters: in -20.0, out -26.0, back -26.0 (before: -20.0 all three) |
| `live`, `transparent.dsp` | refused: shape differs | nothing changed |
| `commit` | done, changed | installed file and the pin in `owner.conf` both 7fd7f047; no restart |
| `live`, `dsp-unity.dsp` | done, applied | out -20.0 |
| `live` with `revert` | done, applied | out -26.0: the committed file |
| `systemctl restart usb16x16-dante` | active | came up on the committed file (`preset="verify-unity-half"`): the wrapper accepts the committed pair |
| `remove` `trial` while live | refused: it is the live profile | |
| `profile` `direct`, expecting `dante-trial` | done | `owner.conf` back to `METERS=1`; the old command line plus the meter file; no live file left in `/run/usb16x16-dante/` |
| `remove` `trial` | done | file gone; the AES67 presets in the same directory untouched |
| `profile` `direct` again | refused: already live | |

The service was restarted three times by this (preset, the manual restart,
direct), each on its first attempt with `NRestarts` 0; it is `direct` with
meters again since about 22:06 UTC, on an aged anchor, the neighbour entry
REACHABLE. With this the service form has carried a preset, live updates
and a commit. Still not exercised: a rollback on the real unit (no start
failed), the wrapper's refusal under the unit, a reboot on this form, an
hour at 308 biquads.

The unit's description still reads "switch the AES67 service": cosmetic,
left for the web step, which touches those files.

## The web service and the page on the Dante stack: written, tested, staged (2026-10-11, about 22:45 UTC)

**`usb16x16-web` 1.5.0 (28ba4501)** serves the stack in service, by the
applier's rule (`USB16X16_STACK`, else Dante when its unit is enabled at
boot). On Dante `/api/health` carries `"stack": "dante"` and:

| Field | From |
|---|---|
| `services` | `usb-16x16`, `usb16x16-dante`, `usb16x16-statime`, the governor |
| `profile` | `owner.conf`: `direct` (the one accepted row) and a user row per `/etc/usb16x16/dsp/dante-<slug>.dsp`, titled from the artifact's `preset` line, with its shape key |
| `owner` | the endpoint's newest `OWNER`, `USB`, `DSP` and `METER` lines, one `journalctl -n 80` every 10 s in the tier the AES67 daemon reads used; a `DSP` or `METER` line older than the `OWNER` line is not reported |
| `meters`, `dspLive` | `/run/usb16x16-dante/meters.txt` (three taps), `dsp-live.status` |
| `mode` | running when the Dante unit is active; `direct` or `dsp` by the configuration |

No `bridge`, `stage`, `recovers`, `ptp` or `streams` on this stack. The
request routes name presets `dante-<slug>`, allow a switch to an installed
preset, and word their answers for the stack; logs read the Dante units
(`service=stack`). The unit file is unchanged: its sandbox already allows
every read this adds.

**The page.** Every word that names the stack comes from `stackTerms(health)`
in `work/web-ui/backend.mjs`. On a Dante Pi: "Dante service", "Dante
endpoint", "Dante network", `dante-<slug>`, the Direct button without
"bridge", the outage as a few seconds with return channels up to about 20 s,
the endpoint's loader, Dante log choices and commands, an Operating-modes
text that says routing is Dante Controller's, and System overview rows from
the endpoint's telemetry (USB host link, clock servo, depth, resyncs and
re-primes, USB faults and detaches, loop gap, DSP stage cost) in place of
the bridge's. The AoIP DSP source is disabled there and a draft set to it is
not offered for install. With no backend, or on AES67, the page reads as
before; the one change there is the offline row "Clock / USB / queue
health" (was "PTP / ...").

Tests: `test_dante_web.py` (10), Dante cases in `backend.test.mjs` and
`workflows.test.mjs` (7 more, each asserting the text carries none of
AES67, bridge, PTP, supervisor, RAVENNA); 100 Python and 113 node tests
pass. Seen in a browser against the real service run locally in Dante mode
with a mock configuration: both pages render, no console error, none of
those words anywhere on either page or in a tooltip. Run read-only on the
Pi, the new collector reports the real state: `dante`, `direct`, all four
units active, the owner's telemetry 1 s old, three meter stages, Apply
available.

**Staged, not installed:** `~/usb-16x16-work/web-control/` holds
`usb16x16-web` 28ba4501, `usb16x16-apply.service` 23cb5b2e (description
only), `install-web-control.sh` 8c5b4200. The page's files wait in
`~/usb-16x16-work/web-ui-next/` and are copied into `web-ui/` once the
service is installed (the new page's Dante log choice needs the new
service). Operator:

```
sudo ~/usb-16x16-work/web-control/install-web-control.sh
sudo systemctl restart usb16x16-web.service
```

Not done: the page itself has not been used against the Pi (it sits behind
the operator's login); meters, a Compile & apply and a live edit from his
browser are the test. The page's own README is not yet brought up to date.
