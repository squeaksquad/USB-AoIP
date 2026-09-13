# Live coefficient updates: EQ and bass-management preview without a restart

Design note, 2026-09-13. Nothing here is built. The accepted bridge, the
supervisor's pinned hash, the applier and the UI are untouched. This is the
"Coefficient updates" paragraph of `DSP_MODE_DESIGN.md` worked out to the
point where it can be built, plus the two halves that paragraph does not
cover: how a new coefficient set reaches a running bridge, and which UI
edits are allowed to take that path.

The operator's question was: can the UI preview EQ and bass-management
edits live? Today it cannot. `POST /api/apply/preset` compiles the draft in
the browser, the applier installs it as `user-<slug>` and runs a profile
switch, and the supervisor restarts the stack: audio is gone for about a
minute per edit. The bridge has no control channel of any kind. `DspStage`
loads its artifact once, before any device is opened (`main.cpp`, the
`--dsp-preset` block), and after that only `process()` is ever called on
it.

Priority: this sits behind the AoIP-only item in the standing order. It is
recorded now so the work is scoped, not so it starts.

## What "live" can mean here, and what it cannot

The audio thread's rules do not move: no allocation, no lock a non-audio
thread can hold, no half-written coefficient set, and no new thread after
capture starts (the meter publisher's lesson, 2026-09-11 22:51 UTC: a
`std::thread` created under `mlockall(MCL_FUTURE)` after the captures were
running cost a RECOVER pair on every start).

Within those rules, a running `DspStage` can take a new set of **numbers**
but not a new **shape**:

- **Live (coefficients):** the five values of every biquad section, every
  mix gain in `expand` and `assign`, every output gain, every output delay.
- **Restart (shape):** the internal channel count, the set of `(dest,
  source)` pairs in either mix, the number of branches and which internal
  channel each one filters, and the section count of every branch and every
  output.

The shape is everything the loader turns into a *count* or an *index*; the
coefficients are everything it reads with `real()`. `sections_`, `states_`
and `delay_lines_` are sized by the shape at load and never resized. A
coefficient swap keeps `states_`, so a gain or frequency move does not click
and a filter does not restart from silence.

This is the whole design in one sentence: **the compiler must emit a fixed
shape for a given routing, so that every knob the user is likely to drag
changes only numbers.**

## Why the compiler has to change first

`compile.mjs` today emits the *minimal* pipeline. That is the right thing
for a soak and the wrong thing for a preview, because it makes shape depend
on values:

- A band that is disabled, or whose gain is exactly 0 dB, is not emitted
  (`compile.mjs:42`). Dragging a band's gain through 0 dB changes the
  output's section count.
- Bass redirection off drops every main high-pass and every bass branch
  (`compile.mjs:83,128`); a bass send that carries nothing is not a row.
- A muted output has no `assign` row at all (`compile.mjs:242`) rather than
  a row with gain 0.
- A crossover of order 2, 4 or 8 is 1, 2 or 4 sections
  (`bridge-artifact.mjs`, `ORDER_SLOPE`), so a slope change is a shape change.

The change is a second emission mode, `shape: 'fixed'`, used only for the
live path and for the user preset that the live path starts from:

1. **Bands.** Every output emits all 16 bands, in band order. A disabled or
   0 dB band is the unity section `b0=1 b1=0 b2=0 a1=0 a2=0`. Global EQ
   bypass and the per-output EQ enable become unity sections too. Cost:
   256 sections on every fixed-shape preset, which is exactly the band load
   the 600 s all-16 soak carried (`loaded`, 308 biquads, DSP_MODE_DESIGN.md
   "Measured").
2. **Mix rows.** Every send the bus layout *allows* is a row: each speaker
   output in a bus to that bus's bass branch, each bass branch to each LFE
   or sub output it can feed, each output's main route. A disabled send, a
   muted output or a muted bus is a row with gain 0. The row set is decided
   by the bus layout and roles alone.
3. **Crossovers.** Emitted at the draft's order, as today. A slope change
   is a restart. Padding every crossover to order 8 would make slopes live
   but could push a full layout past 308 sections, and 308 is the count
   the soak licensed; a slope is also the control least likely to be swept
   by ear. Revisit only if it turns out to matter.
4. **Bass redirection off.** Still a restart: the branches disappear. The
   fixed shape is defined for `bassEnabled: true`; with it off the draft
   compiles as today.
5. **Delay.** Emitted as today. Live, with the caveat under "The swap".

The fixed shape must still satisfy the applier's cap (308 stable sections)
or it is refused like any other artifact; a bus layout whose fixed shape
exceeds the cap simply has no live preview, and the UI says so.

`bridge-artifact.mjs` emits from the compiled CamillaDSP object, so the
padding has to be expressed in that object (a `Biquad` with 0 dB gain
compiles to unity already; the emitter needs a `keepUnity` flag rather than
the current omission) and the YAML side must stay bit-identical for the
verification harnesses, which is what `verify-presets.test.mjs` pins.

A **shape key** is defined as the artifact with every `real()` token
replaced by `_`, hashed with SHA-256. Two artifacts are live-compatible
when their shape keys match. The same function in `bridge-artifact.mjs`
(for the UI), in the applier (Python, on the parsed artifact) and in
`DspStage` (C++, on the loaded stage) must agree; the unit tests pin one
vector across all three.

## The bridge

### Two sets, one index

`DspStage` gains a second copy of everything that is coefficient, not
state:

```
struct Coefficients {
    std::vector<Section>  sections;   // sized at load, never resized
    std::vector<double>   expand_gain, assign_gain;   // parallel to expand_/assign_
    std::array<double, kChannels>        output_gain;
    std::array<std::uint32_t, kChannels> output_delay;
};
Coefficients sets_[2];
std::atomic<unsigned> active_{0};
std::atomic<std::uint64_t> generation_{0};
```

`process()` does `const Coefficients& c = sets_[active_.load(acquire)]`
once at entry and uses `c` for the whole block. The mix row vectors and the
chain/output index tables (the shape) stay single and immutable after load.

`publish(const DspStage& parsed)` runs on the control thread: it checks
`shape_key(parsed) == shape_key(*this)`, copies `parsed`'s numbers into
`sets_[1 - active_]`, then stores `active_` with release and bumps
`generation_`. The retired set is not written again until the control thread
has observed `generation_` acknowledged by the audio thread (the audio thread
copies `generation_` into a second atomic after its acquire load; the control
thread waits for equality before the next publish). Two sets are enough
because the control thread serialises publishes.

### The swap

- Happens between blocks, never inside one. `process()` is per render
  (`produced` frames, one period), so the swap granularity is one period.
- Filter state is kept. For biquads this is the no-click property the
  design already claims. It is also why a *large* frequency move on a
  high-Q band can ring briefly: the retained state was produced by the old
  filter. Acceptable for a preview; the note in the UI says "may ring for a
  moment on large moves".
- Delay: `delay_write_[ch]` is reduced modulo the new delay on the block
  where the swap is first seen, so it never indexes past the new length.
  Up to `new_delay` stale samples come out of the line once. That is a tick
  on that output, once, and only when its delay changed. Documented, not
  fixed: alignment delay is set, not swept.
- Not before the prime. The aligned prime renders unfiltered and the stage
  engages on the next render (`renders_after_prime`); a publish that lands
  before that is simply the set the stage engages with.
- Cost on the audio path: one acquire load and one relaxed store per block.
  `dsp_us_max` must not move (see Acceptance).

### The control thread and the channel

Created where the meter publisher is created (`main.cpp` ~2832: before
either capture starts, before `mlockall`, 256 KB stack, demoted to
`SCHED_OTHER`), and only when `--dsp-preset` is set. It is a second
`pthread` with the same construction, not a job added to the meter
publisher: that thread writes every 25 ms and must not wait on a parse.

The channel is a file, for the same reason the meter snapshot and the
applier's request are files: everything in this system already speaks
atomic-rename plus poll, the web service reads `/run/usb16x16/` at its fast
tier, and there is no listener to secure.

- Path: `/run/usb16x16/dsp-live.dsp`, passed as `--dsp-live-file` by the
  supervisor when the profile carries a preset. Root writes it by rename;
  the bridge only reads.
- The control thread `stat()`s it every 50 ms. On an inode or mtime change
  it reads the whole file, runs `DspStage::load()` on it (allocation is
  fine here: control thread, not audio), checks the shape key against the
  live stage, and either `publish()`es or refuses.
- Result line, written by rename to `/run/usb16x16/dsp-live.status`:

  ```
  DSPLIVE gen=<n> sha256=<file> state=applied|refused|ignored reason="..." t_us=<elapsed>
  ```

  `ignored` is the state before the stage has engaged. The BRIDGE line and
  the SUMMARY carry `dsp_live_gen` and `dsp_live_sha` beside `dsp_preset`,
  so a measurement log says which numbers were live when. The startup
  `DSP loaded` line is unchanged.

Any parse or shape failure leaves the active set exactly as it was. A file
that vanishes is not an event. The control thread never touches the audio
thread's memory except through `publish()`.

### Offline runner

`usb16x16-dsp-offline` gains `--swap-at FRAME ARTIFACT2`: process with the
first artifact, publish the second at that frame boundary, continue. Two
pinned tests in `bridge_tests.cpp`:

- Gain-only swap: output after the swap equals a reference run of the second
  artifact whose biquad states were seeded from the first run at the swap
  frame. Sample-exact, proves the state is kept and nothing else moved.
- Shape mismatch: `publish()` refuses, the output equals the first artifact's
  run end to end.

## The applier

A fourth request kind, `live`, beside `profile`, `preset` and `remove`:

```
POST /api/apply/live   {"artifact", "artifactSha256"?, "expectedProfile", "expectedLiveSha256"?} -> 202 {id, gen}
```

The applier, in order, each step in `current.json` as today:

1. `validating`: `parse_artifact` (bounds, every section stable, total at or
   under 308); the live profile must be a `user-<slug>` block (accepted
   profiles are never previewed against); the artifact's shape key must
   equal the installed `user-<slug>.dsp`'s shape key; `expectedProfile`
   must be the live profile.
2. `checking`: `usb16x16-dsp-offline --bench 1`, as for a preset.
3. `pushing`: write `/run/usb16x16/dsp-live.dsp` by rename.
4. `verifying`: poll `dsp-live.status` up to 2 s for `gen` to advance with
   this sha and `state=applied`; `refused` from the bridge is `failed` with
   the bridge's reason; a timeout is `failed` too, and the file is left,
   since the bridge may still pick it up.
5. `done`. Receipt `kind: "live"` with `gen`, `sha256` and the bridge's line.

The live file is **not** the installed preset. A service restart, a
RECOVER-limit restart or a profile switch returns to `user-<slug>.dsp`, and
the applier removes `dsp-live.dsp` whenever it switches profile. This is
deliberate: nothing that has not been through the full preset path survives
a restart. To keep a preview:

```
POST /api/apply/commit {"expectedProfile", "expectedLiveSha256"} -> 202 {id}
```

`commit` copies the live file over `user-<slug>.dsp` (root, 0644), rewrites
that block's hash in the conf through the same validate-on-a-copy and
atomic-replace path the preset kind uses, and does **not** restart. The
supervisor checks the hash only at start, and the running coefficients
already equal the file, so the next start is the same audio.

### Latency of the loop

The applier is a path-triggered unit: each request is a fresh Python
process. The expected loop is UI debounce (150 ms) + path trigger + Python
start on the Pi 5 + `--bench 1` + a 50 ms poll, call it 0.5 to 1 s from
releasing a slider to hearing it. That is a preview, not a knob. Measure
it before deciding whether the applier needs to become a long-lived
process for this kind; do not build the daemon first.

Rate limit: one in-flight `live` at a time (the existing `inFlight` rule);
the UI coalesces edits made while one is in flight into the next request.

## The UI

- **Live edits** (post a `live` request after a 150 ms debounce, only when
  the live profile is a user preset whose shape key matches the draft's):
  band gain, frequency, Q, type and enable; per-output EQ enable and global
  bypass; crossover frequency; high-pass on/off (unity padding); sub and
  LFE send gains and LFE trim; bus gain and mute; output gain, polarity,
  mute and alignment delay.
- **Restart edits** (the existing Compile & apply): crossover slope; bass
  redirection on/off; any bus format, membership, role or routing change;
  headphone bus creation or removal; mode direct <-> DSP.
- The inspector header shows one of three states, computed from the shape
  key alone: **Live**, **Needs apply** (shape differs from the live
  preset), **Not previewable** (accepted profile, no user preset live, or
  the fixed shape exceeds the cap). Existing controls do not move; the
  state line is what changes.
- **Commit** and **Discard preview** buttons appear beside Compile & apply
  while a live generation differs from the installed file. Discard pushes
  the installed file back through the same `live` path.
- `backend.mjs` gains `requestLive`, `requestCommit` and the shape-key
  function imported from `bridge-artifact.mjs`; `app.mjs` owns the debounce
  and the coalescing. Everything decidable is in the tested modules.
- The connection line keeps saying that browser edits change nothing on
  the Pi when no user preset is live. When one is, it says edits preview
  live and are not kept until committed.

## What this does not do

- No preview against an accepted profile. Accepted means soaked as
  installed; a live set on top of it would be an unsoaked operating point
  wearing an accepted name.
- No shape change without a restart, ever. The "restart requirement" the UI
  README already promises stays true.
- No second engine, no CamillaDSP, no socket, no new listener. The trust
  boundary is unchanged: the browser proposes, root validates, the bridge
  reads one file it does not own.
- No pitch, transport or alignment fields. Coefficients only.

## Acceptance

The bridge binary changes, so this is a new operating point under the
standing rule: four loaded 800-impulse runs and a ten-minute sixteen-channel
soak, RTL at 32 on a fresh anchor, on the fixed-shape user preset, before
the supervisor's pinned hash moves. Plus, specific to this change:

1. **Direct control.** The new binary with no `--dsp-preset` measures what
   the accepted binary measures. The control thread does not exist in that
   configuration, so this checks only that nothing leaked into the common
   path.
2. **Swap under load.** An 800-impulse run on channels 1-2 while a script
   pushes a band gain toggle on outputs 3-16 every 2 s through the full
   `live` path (about 400 swaps). Pass: harness level and spread as the
   same preset without swaps, zero RECOVERs, `dsp_us_max` within its usual
   scatter, `dsp_live_gen` on the SUMMARY equal to the number of
   requests, every receipt `done`.
3. **Audibility.** A 1 kHz tone at -20 dBFS through an output whose band
   gain is swept in 1 dB steps, captured on the Ferrofish return with the
   wire-listen decoder: no sample discontinuity beyond the coefficient
   step itself. A frequency sweep of a Q=8 band from 100 Hz to 10 kHz in
   ten steps: rings die within 50 ms and nothing else.
4. **Restart semantics.** After a `live` and no `commit`, `systemctl
   restart` of the service comes back on the installed file (BRIDGE line's
   `dsp_live_gen=0`, `dsp_preset` the installed name). After a `commit`,
   the restart comes back with the committed numbers and the supervisor's
   hash check passes.
5. **Refusals.** A shape-mismatched artifact through `live` is refused by
   the applier before it reaches the file; one written to the file by hand
   is refused by the bridge with its reason on the status line and the
   audio unchanged.

Rollback is the existing rule: the previous binary stays in
`artifacts/pi-aarch64/`, the supervisor's hash is what selects it, and
removing `--dsp-live-file` from the profile leaves the control thread
never started.

## Order of work

1. Compiler: fixed-shape emission, the shape key, tests (Mac only, inert).
2. Bridge core: two sets, `publish()`, shape key, the offline runner's
   `--swap-at`, unit tests (builds on the Mac through `dsp_offline`).
3. Bridge main: control thread and the two files. Built on the Pi with the
   service stopped, the acceptance battery, hash pinned.
4. Applier: `live` and `commit`, `test_apply.py`.
5. UI: the three states, debounce, Commit and Discard.

Steps 1 and 2 need no Pi time and no service stop. Nothing before step 3
changes what runs.
