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
