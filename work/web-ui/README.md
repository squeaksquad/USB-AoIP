# USB 16x16 web control / DSP design prototype

The Raspberry Pi appliance UI. It runs two ways from the same files.

**Connected**, served by `work/web-control/usb16x16-web` on the Pi: live device
health, live journal reads and presets stored on the Pi. Everything it shows is
read; the service has no endpoint that can change device state, so mode
switching, service restarts and DSP application remain manual work on the Pi.

**Standalone**, served by any static file server: an interactive design
prototype. Every live panel falls back to "Not connected" rather than showing a
stale or invented value, and presets go to browser storage.

Either way it does not process audio, invoke services, or generate deployable
CamillaDSP YAML. Meters are the bridge's live tap when the service reports one, synthetic display activity otherwise; measured
latency and added DSP cost remain explicitly unavailable. The existing bridge is
unchanged.

## Run and check

Connected, on the Pi — see `work/web-control/README.md` for the install:

```sh
sudo systemctl enable --now usb16x16-web.service
```

Then open <http://192.168.1.201:8088> and sign in; the browser prompts once per
session and carries the credentials into the page's own requests. The header
pill reads LIVE · READ-ONLY when the control service answered. Basic auth here
is a lock on a trusted LAN, not wire protection — there is no TLS.

Standalone, from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory work/web-ui
```

Open <http://127.0.0.1:8765>. No package installation, frontend build, external font,
CDN, or cloud service is required. Serve via HTTP; ES modules are not intended to
be opened with a `file:` URL. The Python server is a local preview server only.

```sh
node --test work/web-ui/*.test.mjs
node --check work/web-ui/app.mjs work/web-ui/backend.mjs
```

## What the backend supplies

`backend.mjs` probes `/api/health` once on load, then polls it every 2 s and
stops while the tab is hidden. The service publishes one cached snapshot, so the
Pi pays the same whether one browser or ten are open. When the probe fails the
page returns to its standalone behaviour, including moving presets back to
browser storage; the transition is announced rather than silent. A `401` counts
as a failed probe, so revoked credentials drop the page to standalone rather
than leaving stale numbers on screen.

- **System overview** replaces its placeholders with service states, USB gadget
  link, PTP lock and grandmaster, AoIP link speed, bridge telemetry (servo ppm
  and phase, queue depths and floors, PCM restarts, dropped and clipped frames),
  session recovery count, supervisor stage, stream counts and sink delay, CPU
  temperature, throttling and load. A reading the service could not take says so;
  none of them defaults to zero or to healthy. An unanswered daemon API reads as
  an unknown clock, not as an unlocked one. A 100 Mbit fallback on the AoIP link
  is called out against its expected 1000.
- **Logs** reads the journal for the same unit allowlist the copyable commands
  use, up to 200 lines. Pasted snapshots still work and the count line always
  says which of the two is on screen.
- **Presets** move to the Pi, so any browser on the appliance sees the same set,
  with a Delete control. They are still UI configuration; saving one applies
  nothing.
- **Mode and DSP** report what is actually running. The Pi runs the direct
  USB ↔ AoIP bridge; DSP processor mode stays a draft, and the panel names what
  is still missing before it could run.

- **Meters** (2026-09-11) come from the bridge's own tap when `/api/health`
  reports `meters.available`: the page reads `/api/meters` at up to 10 Hz while
  the Outputs tab is visible, draws the window's peak in dBFS on the input bank
  (USB from the host, before the DSP stage) and the output bank (what leaves on
  AES67, after it), and holds a clip mark for 1.5 s whenever a channel's
  cumulative clip count moves. The summary and the toggle say "live"; with the
  tap absent or stale for 1.5 s the page falls back to its synthetic display
  activity, labelled as such. Mutes and roles do not shape live values: they
  are what the wire carries.

Not supplied, on purpose: any control action beyond Apply (the service
answers 501 to the other control routes so the boundary is visible from the
API).

## Agreed scope

- One global source bank: 16 USB channels **or** 16 AoIP channels at 48 kHz.
- DSP output: 16 AoIP channels total, shared by speaker, subwoofer and headphone buses.
- Multiple named buses share that physical output budget, with separate bus level
  and mute controls. A speaker layout and stereo headphones can coexist.
- Every output: 16 IIR PEQ bands, gain, mute, polarity and 0–10 ms alignment delay.
- The 10 ms limit is **user-selected speaker alignment**, not a processing-latency budget.
- Bass management: per-input speaker HP and bass LP, selectable crossover slope,
  source-to-sub gains, and independently filtered/trimmed/routed LFE.
- Source choice is global. Per-channel USB/AoIP mixing is outside this first scope.
- Headphones can select a stereo input pair or an editable stereo downmix from
  that source bank, before speaker crossover processing. This is ordinary stereo
  mixing, not binaural rendering or a headphone virtualization engine.
- Direct USB ↔ AoIP bridge mode remains available separately from DSP mode.
- Metering, output mapping, settings and complete presets belong in the web UI.

The example is 7.1.4 source content with 11 speaker outputs, two sub outputs and
three spare outputs. It illustrates the UI; it is not a measured room calibration.
The first sub (labeled LFE) is on output 4; the second is on output 13. Left-side
bass goes to the first sub, right-side bass to Sub 2, C and LFE go to both at
independent -6 dB send trims. A common -18 dB input trim reserves summing headroom;
it is an example value, not an automatic calibration or clipping guarantee.
All output PEQs start flat and alignment delays start at zero.

## Prototype interaction

The prototype has two pages. **Channels** merges what were separate Outputs and
Bass management pages: output buses, the meter bank, a channel overview where
label, role, source, gain, alignment, polarity and mute are edited in place, and
bass management for the input side. The per-output EQ opens from that overview's
**EQ** button into its own editor dialog, so the long EQ workspace no longer sits
between the overview and bass management. **System & presets** is unchanged.
The Output buses and Bass management blocks are collapsible sections, open on
desktop and collapsed on narrow screens; toggling one is remembered until reload.
Above 1500 px the overview and bass management sit side by side within a 1760 px
measure, so a large display gains a second column rather than ever-wider fields;
the settings grid goes to three columns above 1800 px. On screens at or below
900 px the input meter bank starts collapsed.

The visual style is a Windows XP "Luna" treatment on a current layout: a blue
gradient title bar with Explorer-style page tabs, beige window chrome, white
list surfaces, blue task-pane panel headers, beveled 3D controls with the
period's amber hover, sunken fields, XP scrollbars and a Tahoma-first font
stack. Instrument surfaces stay dark — the EQ graph and the channel meters read
as a media panel inside the window. The EQ editor opens as an XP window, title
bar and red close box included. It is defined entirely in `style.css` custom
properties and surface rules; no markup or behavior depends on it, and spacing,
hit targets and focus behavior are unchanged. The page declares
`color-scheme: light` so native checkboxes, selects and scrollbars stay light
regardless of the host's dark mode.

Data tables follow list-view alignment: each header label sits directly over the
text of the control beneath it (including the few pixels a `<select>` insets its
own text), and numeric columns are right-aligned under right-aligned headers.
The overview's EQ button is a fixed 92 px whatever it reads — `flat`, `3 bands`,
`off` or `all off` — so the column never reflows as bands are added; the full
wording is in its tooltip and accessible name.

- **Channel overview:** one row per physical output with its bus, role, speaker
  source, gain, 0–10 ms alignment, polarity, mute and EQ state. **Bass routing**
  in its toolbar, beside the global EQ controls, expands the per-channel crossover
  and sub-send matrix in place; Bass management below keeps redirection on/off,
  the headroom trim and the LFE branch. Alignment is
  user-chosen speaker delay, not a processing-latency figure. The EQ button shows
  how many bands are non-flat, or that EQ is bypassed for that output or globally.
- **Profile slots A/B:** two complete drafts held in the page for quick comparison.
  Selecting the other slot stores the live draft in the current slot and makes the
  other one live; an empty slot is seeded from the draft you were editing.
  **Copy A → B** overwrites the other slot with the current draft. The **Preset**
  selector beside the slots loads any preset saved in this browser into the live
  slot, so A and B can hold two saved presets and switch between them; it lists an
  Unsaved draft entry whenever the live draft is not a saved preset, and each slot
  remembers whether its draft was saved. Slots themselves live for the session
  only; named presets in System & presets remain the durable store.
- **Outputs:** select one of 16 output strips; assign speaker/sub/unused role,
  choose the speaker source, edit output correction and all 16 PEQ bands. Input
  meters are expanded by default and can be collapsed. Mutes affect synthetic
  output meter activity only. The EQ plot calculates biquad magnitude; it excludes
  crossover response, gain, delay and acoustics and clips its display to ±12 dB.
  Compact meter strips and toolbars bring processing controls closer to the top.
  Controls are sized to their content rather than stretched to their column, so
  single fields no longer span a whole panel on wide displays.
  Above 1100 px, the EQ editor shows bands 1–8 and 9–16 side by side; narrower
  screens stack them in order, with tables scrolling internally as needed.
  The dark EQ graph is 420 px tall on desktop (360/320 px on smaller screens),
  with a ±12 dB display and matching fine drag sensitivity. Band gains retain their
  ±18 dB limits; values outside the display sit at its edge and remain editable.
  It uses colored individual band curves, a yellow summed
  response and a selected-band editor. Click a numbered handle to select it; drag
  horizontally for logarithmic frequency and vertically for gain. **Cmd-drag
  vertically** adjusts Q only (up widens the band, down narrows it); Ctrl-drag is also supported.
  Arrow keys make small frequency/gain changes; Cmd/Ctrl + up/down adjusts Q.
  Escape, pointer cancellation or window blur restores the band to its state before
  the drag. Direct mode and EQ bypass disable graph editing. Disabled bands remain
  selectable; enable On to drag them. The selector also reaches overlapping handles.
  Handles show each band's own frequency/gain, including shelves; the yellow curve
  shows the combined response. Numeric controls and the tables stay synchronized.
  Drag edits round frequency to 0.1 Hz, gain to 0.01 dB and Q to 0.001; untouched
  parameters, numeric edits and imported REW precision are preserved.
  The editor's title bar carries **channel navigation** — previous / next buttons
  around a selector listing all 16 outputs, plus <kbd>Alt</kbd> + <kbd>←</kbd> /
  <kbd>→</kbd> — so another output opens in place without closing the editor; the
  output bank and the overview row follow the selection. This is navigation only.
  The separate **Swap with output** control now sits with copy/paste and REW
  import, where its destructive meaning is clear: it exchanges two physical
  outputs, processing and bass routing included.
  A **band strip** under the graph gives one numbered chip per band: click one to
  select it without hunting for its handle, and Left/Right/Home/End move between
  them from the keyboard. Each chip carries its band's colour, shows bold when the
  band is away from flat and dotted when it is off, and its tooltip and accessible
  name read the band's frequency, gain and Q. On a phone the strip wraps to two
  rows of comfortable targets, which is the practical way to pick a band there.
  The editor body has a 20 px gutter (12 px on phones) so the graph, toolbars and
  band tables share one left and right edge inside the dialog window.
  **Double-clicking a band handle** resets that band, the same edit as its row
  Reset button. Alongside the per-output EQ enable, the editor carries global
  controls: **Bypass all EQ** bypasses every output PEQ while retaining each
  output's own enable and all band values, so switching it off restores the
  response exactly; **Reset EQ** resets the 16 bands of the selected output; and
  **Reset all** resets all 256 bands after a confirmation. None of them change
  gain, alignment, polarity, mute, routing or saved presets. Global bypass is
  stored in the preset and disables graph editing while it is on.
  For a headphones bus, **Link ears** groups the two headphone outputs: band
  edits, resets, REW imports, pastes and the EQ enable apply to both, and turning
  the link on copies the first ear's EQ to the other. Gain, alignment, polarity
  and mute stay independent per ear, and unlinking leaves both as they are.
  Every band row has **Reset**, also available in the selected-band editor. Reset
  restores that band's indexed default frequency, bell filter, 0 dB gain and Q 1.
  Its on/off state, other bands, other outputs and global EQ bypass are retained.
  **AoIP output** in the inspector header swaps the selected channel with the
  chosen destination, including source, label, role, all processing and bass-send
  columns. A spare destination moves the channel and leaves a spare behind.
  Select the former output to swap back. Custom routing is saved in presets;
  importing an older preset preserves its existing order without migration.
- **Bass management:** set speaker high-pass and bass low-pass frequency separately;
  choose Linkwitz–Riley 12/24/48 dB/oct. Each source-to-sub connection has an explicit
  enable and gain. Turning the main's HP off retains its bass send, allowing a
  full-range main plus bass reinforcement. Turning global bass redirection off
  bypasses main HPs and disables all redirected sends, while retaining LFE routing.
  **Set crossover** above the matrix applies one frequency (20–250 Hz) to both
  HP and bass LP for all non-LFE input channels, or a selected group. Check source
  rows to switch to Selected channels; the Source header checkbox selects or clears
  all non-LFE rows. The button shows how many channels will change. Applying is a
  one-time edit: individual HP/LP values remain independently editable afterward.
  LFE settings, slopes, HP enable states and bass sends are preserved. Bulk controls
  follow the same direct-mode and bass-bypass disabling as individual controls.
- **Crossover polarity:** choosing 12 dB/oct on any *active* crossover raises an
  advisory note in Bass management. A 12 dB/oct Linkwitz-Riley leaves its two
  branches 180 degrees apart at the crossover frequency, so the main and the sub
  usually need opposite polarity to sum. The note names the affected inputs and
  branches and **changes nothing** — the right answer depends on drivers,
  positions and the room, and only a measurement settles it. 24 and 48 dB/oct do
  not have this property. A 12 dB/oct slope on an input that drives nothing is
  not flagged, and the LFE branch is judged on the LFE slope rather than its
  input row's. `crossover-notes.mjs` decides this and is shared with
  `work/dsp-compiler`, so the panel and the compiler's report cannot disagree.
- **LFE:** choose its input, low-pass frequency/slope and trim independently. There
  is no implicit +10 dB gain. Changing the designated LFE input clears sends from
  both affected rows; reassign them explicitly. Speaker-source mapping can still
  select the LFE input; in the future engine this uses the filtered/trimmed LFE branch.
- **Roles:** outputs in a headphones bus read as headphones everywhere they are
  labelled — `PHONES L` / `PHONES R` on the output bank strip and Headphone in the
  overview's Role column — rather than as speakers, though they remain speaker-role
  outputs in the preset. Converting an output to/from a sub clears that column's sub sends.
  Newly assigned subs are silent until sends are enabled. Output correction remains
  with the physical output. Up to all 16 slots can be subs; no extra network channels
  are implied by internal mixing buses.
- **System & presets:** save by name in browser local storage, reload, and export or
  import versioned JSON. Saving the same name replaces that local preset. Load,
  import, and reset replace the current draft. Unsaved edits are lost on page reload;
  saved presets remain available in the selector. Exported JSON is a UI document,
  not CamillaDSP configuration. Browser storage is origin-specific.
  **Logs** provides AES67/USB journal commands and a local pasted-snapshot viewer
  with case-insensitive text filtering. Each service selection keeps its own pasted
  text (up to 200,000 characters) until page reload; it is not stored in presets,
  uploaded or presented as live telemetry. Live refresh is disabled offline.
  **Common commands** offers copyable AES67/USB status and restart commands for a
  terminal on the Pi. USB restart stops AES67 before restarting the gadget and then
  starts AES67; the command chain stops on error. Restart commands interrupt audio.
  Run buttons remain disabled until a control backend exists. No service action is
  executed by this prototype, and no Pi changes are part of this UI update.
- **Direct mode:** disables DSP output and bass controls and retains their draft.
  Mode/source buttons preview a proposed state; no running hardware state is claimed.

### Output formats and channel copy/paste

**Output buses** groups physical outputs into independent listening destinations.
The default remains one Speakers bus; headphones are added explicitly. For a
7.1.4 system with headphones, assign the speaker layout to outputs 1–12 and the
stereo headphone bus to outputs 15/16. All buses share the same 16-output limit;
an output cannot belong to two buses. Bus gain and mute sit alongside each output's
own gain, mute, EQ and alignment.
New buses use free outputs; headphones default to the last free pair and then
carry **Left output** and **Right output** selectors on their bus card, listing
all 16 physical outputs with what currently owns each one. Choosing a free
output moves that ear onto it; choosing one held by another bus exchanges the
two channels, with labels, EQ, gain, alignment and bass routing following each
channel, so no output is ever owned twice. Move individual
channels using the existing AoIP output selector. Speaker buses share input
crossover/LFE settings and the global bass bypass; their output correction,
allocation, levels and mutes are independent. Removing the last speaker bus clears
its outputs and retains an empty bus that can receive another format.

Headphones offer **Independent stereo pair** and **Surround stereo downmix**.
Switching modes retains both the selected input pair and the downmix coefficients.
Advanced downmix controls set the level from each of the 16 source inputs to the
left and right ear separately; excluded inputs contribute nothing. These are
editable routing coefficients, not measured room or headphone calibration. The
common input headroom trim applies before summing, and LFE is excluded by default.
Both modes use the full-range source before speaker crossovers, retaining each
headphone output's own EQ and alignment.

Bus configuration is included in version 2 presets. Version 1 presets migrate to
one Speakers bus around their existing active outputs, preserving channel order,
processing and routes. Import does not silently reserve outputs for headphones.

The Outputs page offers Stereo (2.0), 2.1, 2.2, 5.1, 5.2, 5.1.2, 5.1.4, 5.2.4,
7.1, 7.2, 7.1.2, 7.1.4, 7.2.4, 9.1.4, 9.1.6 and 9.2.4. Surround presets default
to Dolby output order: L, R, C, LFE, side surrounds, rear surrounds (if present),
wides (if present), then heights front to back. In 7.1.4 the first 12 outputs are
**L, R, C, LFE, Ls, Rs, Lrs, Rrs, Ltf, Rtf, Ltr, Rtr**, matching
[Dolby's channel listing](https://ott.dolby.com/OnDelKits/AC-4/Dolby_AC-4_Online_Delivery_Kit_1.5/Documentation/Specs/AC4_DASH/help_files/topics/MPEG_dynmc_adpt_strmg_c_mpd_auchlconfig_ac4.html)
(Lb/Rb and Tfl/Tfr/Tbl/Tbr are alternate abbreviations). The LFE output is a
sub sum and also receives any enabled redirected bass. A second physical sub is
appended after the standard single-LFE path; it does not shift the main channels.
Stereo subs follow L/R. Remaining slots are unused.

9.1.6 uses all 16 outputs, with LFE on 4. 9.2.4 puts LFE on 4, Sub 2 on 15,
and leaves 16 spare. Input order is unchanged: wides use inputs 13/14, top-middle
uses 15/16, and front/rear heights retain 9/10 and 11/12. Review Speaker source
for each output if the source uses a different order. Input labels remain
user-editable; applying a format does not rename them. USB host channel labels
remain 1–16.

Choose a bus format and press **Apply format**. This resets that bus's output labels,
roles, source assignments, bass sends and output correction to the layout defaults.
Other buses, input settings, source selection and preset name remain unchanged.
One sub receives the layout's active main bass plus LFE; two subs use left/right
sends with Center and LFE sent to both. Global bass bypass remains an explicit
shared control. **Undo last bus format** restores the affected bus's output bank
and send columns, including EQ and delays, while retaining unrelated bus edits.
Loading/resetting/importing a complete preset clears this undo point. To make a
custom route, change AoIP output, or edit individual output roles and sources.

**Copy channel** stores a snapshot in the page's internal clipboard. Select another
output and choose **All output processing** or **EQ only**, then Paste. Full
processing includes EQ enable/bands, gain, delay, mute and polarity. EQ-only paste
leaves the other processing settings intact. Both preserve the destination's label,
role, source mapping and bass routing. The clipboard lasts until the page reloads.

### Import from REW

In REW, select the **Generic** or **CamillaDSP** equaliser and use **Export filter
settings as text**. On the selected output, open **Import REW EQ**, choose the `.txt`
file or paste its contents, review the filter count, and press **Import EQ**.
This replaces only that output's PEQ bands and enables its EQ. Gain, delay and
routing are unchanged. Remaining unused bands are disabled.

Supported text filters are PK/PEQ and shelves with explicit Q (LSQ, HSQ, LS, HS).
The importer preserves decimal precision, including decimal-comma exports, and
skips OFF/None rows. It rejects unsupported active filters, duplicate numbers,
malformed filter lines, non-Generic/CamillaDSP equaliser headers, more than 16
enabled filters, and values outside the existing UI limits (20–20,000 Hz, ±18 dB,
Q 0.1–18). It does not silently clamp values or drop active filters. Shelf types
without explicit Q are rejected rather than assigning a guessed shape. Native
REW `.mdat`/`.req`, coefficient files, YAML and formatted CSV are not accepted by
this text importer. Input is parsed locally and never uploaded to a server.

REW documentation: [EQ filter text export](https://www.roomeqwizard.com/help/help_en-GB/html/eqwindow.html),
[equaliser definitions](https://www.roomeqwizard.com/help/help_en-GB/html/equaliser.html).

### Live preview (2026-09-13, step 5 of `work/phase4-bridge/LIVE_COEFFICIENTS_DESIGN.md`)

When the Pi is running a user preset that the bridge takes live updates on,
edits go to the running bridge as they are made, with no restart. Whether an
edit can go live is decided from the **shape key** alone: the compiled
artifact with every gain, delay and coefficient blanked, hashed, computed the
same way here (`bridge-artifact.mjs`), in the applier and in the bridge. The
EQ editor and the Settings panel show one of three states:

- **Live.** The live profile is a user preset with `DSP_LIVE=1` and the draft
  has its shape. Every edit compiles the draft in the fixed shape, and
  `live.mjs` debounces (150 ms), keeps only the newest draft and has at most
  one request in flight; `POST /api/apply/live` hands the artifact to the
  applier, which checks it and gives it to the bridge. Band gain, frequency,
  Q, type and enable; output EQ enable and global bypass; crossover
  frequency and a 12 <-> 24 dB/oct slope; high-pass on and off; bass
  redirection on and off; send gains; LFE trim; bus gain and mute; output
  gain, polarity, mute and delay are all live edits.
- **Needs apply.** Same profile, different shape: routing, a bus format or
  membership, a 48 dB/oct slope, or an input's first send. Compile & apply runs it, with the restart that implies.
- **Not previewable.** No Pi, Apply not installed, an accepted profile live
  (live edits never touch an accepted profile), or a user preset installed
  before live updates existed (re-apply it).

A live update is not kept: a restart returns to the installed preset. While
the bridge runs coefficients that differ from the installed file, Settings
shows **Commit preview** (`POST /api/apply/commit`: the running coefficients
become the installed file, no restart) and **Discard preview** (the installed
file is handed back to the bridge). The page's expectation of what the
bridge last applied travels with every request and a stale page is refused;
on such a refusal the page forgets its expectation and the next edit carries
the bridge's current hash. When the bridge reports coefficients the page did
not send (a second tab, a test pusher), the page re-sends its draft once per
such state and not again until the user edits, so two authors converge
rather than loop.
Compile & apply itself now emits the fixed shape, so every user preset
installed from here on is a live base; the confirm text says how many bands
shape the audio and how many are held at unity.

## Processing architecture

```text
16-channel source selector: USB capture OR RAVENNA capture
  -> common input headroom trim
  -> split to speaker buses and full-range headphone buses
     headphone bus: selected input pair OR per-input stereo downmix
       -> bus level/mute -> per-output PEQ, alignment, gain/polarity/mute
     speaker buses: internal split into main and bass branches
       mains: optional per-input HP, or full-range bypass
       bass: per-input LP -> independent send gains -> one sum per sub output
       LFE: independent LP + trim -> independent sends into sub sums
  -> output assignment within each bus (speaker branch, sub sum, or silence)
  -> bus level/mute
  -> per-physical-output 16-band IIR PEQ
  -> per-output gain, polarity, 0–10 ms delay and mute/ramp
  -> 16-channel RAVENNA playback -> AoIP transmit streams
```

The implementation should give every channel equal baseline buffering. IIR filters
still introduce frequency-dependent phase/group delay; equal block latency does not
make a crossover phase-neutral. The initial UI exposes LR slopes with independent
HP/LP cutoffs; matching cutoff/slope, polarity, speaker response and acoustic alignment
must be checked together. In particular, 12 dB/oct LR crossover branches may require
relative polarity inversion for summation; do not silently treat all slope choices
as interchangeable acoustic alignments.

At 48 kHz, 10 ms equals 480 samples. Whole-sample delay should be the first engine
implementation; show the actual quantized delay (20.833 µs/sample) in the connected
UI. Delay storage itself is small (30,720 bytes for 16 × 480 float32 samples, before
implementation overhead). 16 × 16 PEQ bands is 256 biquads / 12.288 million biquad
sample evaluations per second, before crossover and transport work. These counts
are sizing arithmetic, **not a measured CPU percentage or latency guarantee**.

CamillaDSP can express the branch expansion, IIR filters and mixing. A compiler
should allocate internal channels as needed, then contract to exactly 16 outputs.
Crossovers do not consume any of the user's 16 output PEQ bands. Keep the preset
schema independent of CamillaDSP YAML and validate the generated pipeline with the
specific installed engine version before use. No compiler is implemented here.

## Control service and real-time boundary (proposed)

The browser draws meters and EQ curves. A separate unprivileged control process on
the Pi serves static files and provides status, preset validation and control APIs.
Audio must keep running if the browser closes, a client is slow, or the web service
crashes. HTTP/JSON work, file I/O and browser backpressure must not run in or block
the audio thread. Never open competing ALSA streams merely to obtain meter values.

Meter statistics should be computed with bounded work on buffers already passing
through the engine, published through preallocated nonblocking snapshots, and
fanned out at 15–30 Hz maximum. Accumulate peaks across publication intervals so
short overloads are not lost. Slow clients receive the latest snapshot; they do not
build an unbounded queue. Idle/background clients unsubscribe or slow down. Reuse
CamillaDSP's metering API when DSP is active; bridge metering needs a separately
benchmarked tap. The prototype uses a 10 Hz cosmetic meter animation only.

The existing bridge has a telemetry thread and atomic counters in
`work/phase4-bridge/src/main.cpp`. The AES67 supervisor provides a `status` command
and profile switching, but **switch-profile restarts audio**. Polling that command
at meter rate is inappropriate. Read status slowly and share cached snapshots.
The current `/api/sink/status/N` arrival-lead minimum resets when read. Give it one
collector owner and expose interval boundaries/sequence IDs to dashboards and the
measurement harness; independent readers would invalidate interval comparisons.

Application contract. `work/web-control/usb16x16-web` implements the read half:

| Operation | Behavior | State |
| --- | --- | --- |
| Read state | Actual mode/source, connection, PTP, USB, streams, engine health and applied revision; unavailable is not zero/healthy | `GET /api/health` |
| Subscribe meters | Timestamped input/output peaks and RMS with clipping counters, tap location, mode and revision | `GET /api/meters` (2026-09-11): the bridge's 50 ms window per stage, peak and RMS in dBFS, cumulative clip counts, stage names and where they sit; polled, not pushed |
| Read/write preset | Versioned configuration, separate from applied device state | `GET/PUT/DELETE /api/presets` |
| Validate draft | Schema + output budgets + installed engine compatibility; return restart requirement and proposed changes | Not implemented |
| Apply revision | Serialized operation with expected revision and operation ID; never launch two owners of a PCM device | `POST /api/apply/profile` (2026-09-11): a switch between accepted profiles only, the browser naming the profile it believes is live; the root applier `usb16x16-apply` does the stop / switch-profile / start / verify / rollback and writes a receipt. Applying the editor's own draft is still not implemented |
| Read operation | Validating / fading / stopping / starting / verifying / running / rollback / failed | `GET /api/apply/status`: validating / stopping / switching / starting / verifying / settling / done / rolling-back / rolled-back / failed / refused. No fade: the supervisor's restart is what it is |

Keep live status, editable draft and last applied preset distinct. Reject stale
edits rather than silently overwriting another client's applied revision. Persist
presets atomically. A narrow local privileged supervisor should own service changes;
do not expose arbitrary shell commands or unrestricted configuration paths. Bind
management to the intended interface and authenticate writes before a networked
release; never expose unauthenticated CamillaDSP control to arbitrary clients.

## Mode integration decisions for the hardware phase

- **Direct:** preserve the accepted existing duplex bridge profile and USB identity,
  channel count and names. No DSP buffer or filter should remain in its audio path.
- **USB -> DSP -> AoIP:** retain USB/AES67 clock-domain matching. Do not simply
  replace the proven bridge with CamillaDSP and assume clock drift is solved. Choose
  one clock-control owner per domain; benchmark insertion via internal endpoints
  against a separately validated Camilla capture/playback topology.
- **AoIP -> DSP -> AoIP:** RX and TX belong to the AoIP clock domain. The service
  must operate without a USB host; inspect/refactor USB-dependent startup gates in
  an isolated change. Do not stack an independent rate servo on the AoIP clock.
- All current network references mean **AES67 interoperability with compatible
  Dante devices**, not a native Dante endpoint or arbitrary Dante subscription API.
  Use distinct source and processed-return streams/channels for a same-device loop;
  the processed return must not feed its own input.
- First mode changes are controlled mute/fade, stop previous PCM owner, configure,
  start, verify PTP/data flow/engine state, then unmute. Rejected/failed operations
  should remain muted or restore a verified last-working mode and report the result.
  Do not promise seamless switching or live-safe filter topology edits.
- Allow the user to review which setting changes interrupt audio. Initial hardware
  application is a deliberate Apply operation; browser edits are not immediate sends.

## Delivery sequence and acceptance

1. **This pass:** reviewable static UI, schema and sizing/control architecture.
2. **Read-only backend:** live health and metering behind bounded collection; compare
   UI disconnected, one active client, multiple clients and reconnect storms with
   the accepted bridge, keeping its operating profile fixed.
   *Health, logs and presets are implemented in `work/web-control`. Metering is
   not: it needs the separately benchmarked bridge tap this document asks for.
   The multi-client and reconnect-storm comparison is still outstanding — the
   single cached snapshot makes client count cheap by construction, but that has
   not been measured against the bridge.*
3. **DSP configuration compiler and offline verification:** generate CamillaDSP YAML;
   use known multichannel files to verify channel isolation, bass matrices, LFE gain,
   band response, polarity and 0/480-sample delays. Check coherent worst-case sums and
   true output clipping with all channels driven. Define the headroom policy explicitly.
4. **Isolated DSP service:** validate USB and AoIP source modes independently, then
   mode transitions and startup/failure recovery, preserving direct-mode rollback.
5. **Hardware control:** enable staged Apply only after the underlying operations and
   validation are established. Integrate a tailored PEQ UI first; advanced CamillaGUI
   access can follow with configuration ownership clearly defined.
   *First cut 2026-09-11, after the DSP bridge and its two pinned presets were
   accepted: the Settings page's "Service profile" panel switches the AES67
   service between accepted profiles through `work/web-control`'s Apply
   (request file, root path unit, verified restart, automatic rollback, receipt).
   Draft and applied state stay distinct: the editor's preset is compiled here,
   in the browser, with the verified compiler served as `./compiler/*.mjs`, and
   only the resulting artifact goes to the Pi, where the applier validates it by
   loading it through the bridge's own code before installing it as a
   `user-<slug>` profile (STATUS user, never accepted; see
   `work/web-control/README.md`, "User presets"). Metering and AoIP-only mode
   remain out of scope.*

Acceptance requires sample-accurate latency measurements with intentional alignment
delay zeroed, the 64-sample host test where USB is involved, and separate AoIP-only
measurements. Run a loaded ten-minute soak using all 16 outputs, all 256 bands,
crossovers and multiple sub sums, with active UI clients. Reject recoveries, lost
audio, sustained queue-reserve decline, or deadline failures. Record CPU, temperature,
throttling, queue margins and clipping along with timing; do not equate a page loading
or numeric latency alone with an accepted operating point. No Pi performance claim
is established by this browser prototype.

## References

- [CamillaDSP engine, mixers, filters and pipeline](https://github.com/HEnquist/camilladsp)
- [CamillaDSP metering/control API](https://github.com/HEnquist/camilladsp/blob/master/websocket.md)
- [CamillaGUI](https://github.com/HEnquist/camillagui)
- [Sphere bass-management reference](https://www.gingeraudio.com/sphere-immersive-monitor-controller)
- [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) for the response plot
- Local integration evidence: `work/NEXT_SESSION_PROMPT.md`,
  `work/phase4-bridge/src/main.cpp`, `work/aes67-bridge/usb16x16-aes67-supervisor`,
  and `PROJECT_HANDOFF.md` rollback rules. Consult the latest live state before deployment.

## Verification of this prototype

- Crossover polarity note: 10 new tests in `crossover-notes.test.mjs` cover which
  crossovers are active (high-pass only where a main branch exists, low-pass only
  where a bass branch does, the LFE branch on the LFE slope), bass redirection
  off, an input with its crossover switched off, a headphone-only source, no note
  at 24/48 dB/oct, the note naming affected inputs and branch counts, an inactive
  12 dB/oct slope not being flagged, and that nothing in the module edits the
  preset. Browser checks set 12 dB/oct through the LFE slope control and through
  a per-input slope in Bass routing: the note appeared with the right branch
  counts, disappeared on returning to 24, left every output's polarity untouched,
  and did not unmount the select being edited. The note lives in its own
  container refreshed in place, because the change handler is deliberately
  surgical and does not re-render the bass panel on a slope edit.
- Narrow-width regression found and fixed: the live connection line is far longer
  than the "Not connected" placeholder it replaced, and an existing
  `.connection-status > span { white-space: nowrap }` pushed the page to a
  535 px scroll width at a 390 px viewport. With wrapping allowed the page is
  back to 413 px, matching the pre-backend baseline measured from commit
  d70f0b8. The residual 413 px is pre-existing, from the channel-overview
  toolbar, and is untouched here.

- Read-only backend: 69 Node tests pass (was 49), with 20 new covering the
  client — probe rejecting a non-`ok`, non-JSON, array or failed response;
  log requests carrying the right service and surfacing service errors; the
  offline facts reading unavailable with nothing marked healthy; a healthy stack
  grading ok; a 100 Mbit link, a dead link, a failed unit, a lost PTP lock,
  stale telemetry and dropped frames each grading bad or warn; an unanswered
  daemon API reading as an unknown clock rather than an unlocked one; missing
  readings being omitted rather than defaulted; both preset stores round-tripping,
  the browser one keeping a `__proto__` name as an own key, and the Pi one
  reporting a rejected write and skipping one unreadable preset instead of
  losing the list.
- The service was exercised on a workstation (every Pi-specific read reporting
  unavailable), then against the running Pi: the header pill read
  LIVE · READ-ONLY, the overview showed the three services running, PTP locked to
  `00-1D-C1-FF-FE-1D-27-DC`, eth0 at 1000 Mbit/s, telemetry 0 s old, queue floors
  28/66, 0 dropped and 0 clipped, sink delay 103, 46.6 °C and no throttling.
  Refresh live logs returned 200 journal lines, and a preset saved from the
  browser appeared under `~/usb-16x16-work/web-presets`.
- Path traversal (`/../../etc/hosts`, percent-encoded), an unknown log service,
  an invalid preset name and `POST /api/service/restart` were each refused.
  Staging the files and running the service left the bridge unchanged: recoveries
  3 before and after, PCM restarts 2/1, queue floors 28/66.

- Channel navigation in the EQ editor: previous / next, the output selector and
  Alt + arrow all move the editor between outputs with the dialog open, and the
  output bank strip and overview row highlight follow; the swap control, moved out
  of the title bar and relabelled, still exchanges two outputs with their
  processing (verified by shaping band 1 on output 1, swapping to 6, and finding
  the edit on its new home). Checked at 390 and 1280 px.
- EQ dialog padding and band navigation: the editor body is a padded panel rather
  than a flush one — measured 21 px of gutter on both sides at 1280 px and 13 px at
  390 px, with the title bar still full width — and the new band strip was checked
  by clicking a chip (editor, graph and tables follow), by keyboard (Right and End
  move the selection and focus together), and for its off / away-from-flat states
  after disabling one band and shaping another.
- Output buses rebuilt on one grid: each bus card is now a titled group box with
  Remove at its top right, then a single label row over a single control row
  (bus name, output format, Apply format, bus gain, mute) instead of a wrapping
  toolbar, and the headphone controls are two XP group boxes — Headphone outputs
  and Headphone source — sharing that same grid, so every label and control lines
  up down the card. The downmix table now sizes its dB columns instead of
  spreading across the panel. A scripted check confirms the label baselines and
  control baselines match within every bus grid at 700, 1280 and 1440 px, and
  after the rewrite bus gain, mute, rename, Apply format, Undo, adding a
  headphones bus, moving an ear and switching source mode were all re-tested.
- Profile bar sizing: the A, B and Copy buttons share one 27 px height so Copy no
  longer outweighs the slots, and the preset selector sizes to its longest name
  (capped at 340 px or 34vw) with the full name in its tooltip; checked with a
  48-character preset name at 390, 1000 and 1280 px without clipping.
- Preset slots, headphone labelling and bass-box update: 49 Node tests pass,
  including new coverage that a headphones-bus output reports PHONES L / PHONES R
  while speakers, subs and spares are unchanged, and that the label helper rejects
  an out-of-range output. Browser checks saved two presets, loaded one into each
  slot from the profile bar, and confirmed switching slots restores each preset's
  alignment and its saved/unsaved status; the bass matrix opened and closed from
  the overview toolbar at 390, 1000 and 1440 px with the page free of horizontal
  overflow; the alignment audit was re-run and its two new findings (the headphone
  output note and the downmix table's numeric headers) fixed.
- Luna theme and alignment update: 48 Node tests pass, app syntax checked.
  Browser checks at 390, 800, 1000, 1440 and 1920 px covered the retheme end to
  end: EQ button width held at 92 px across flat / 3 bands / global-bypass
  states, header tabs gained vertical padding and read as tabs against the title
  bar, an automated pass compared block left and right edges, inline control
  baselines, and every table header against the control text in its column, and
  the fixes it found (page-level heading inset, panel headers not spanning their
  panel, select-column header insets, the overview table clipping its EQ column
  below 1100 px) were applied and re-measured clean. Functional smoke test after
  the retheme: A/B slot switching, adding a headphones bus, moving an ear to
  output 10, linking ears and double-click band reset all still behave. No
  console errors or warnings.
- Headphone routing, density and theme update: 48 Node tests pass. New coverage:
  moving a bus onto chosen physical outputs carrying gain, alignment and labels,
  swapping the two ears, exchanging with an occupied output without doubling
  ownership, and rejecting duplicate or out-of-range choices. Browser checks at
  390, 800, 1280, 1440 and 1920 px moved a headphone ear onto a free output and
  onto an occupied speaker output (the displaced speaker took the freed slot),
  and re-ran the alignment audit over every toolbar, header and inline row with
  no remaining misalignment and no horizontal page overflow.
- Merged-overview update: 44 Node tests pass, along with the app syntax check.
  New coverage: per-output and all-output EQ reset (retaining band on/off states,
  gain, alignment and routing), global bypass round-tripping the calculated
  response exactly, headphone ear linking and unlinking, and A/B slot seeding,
  switching, copying and argument checks.
- Browser checks at 390, 1100, 1440, 1680 and 1920 px: the EQ dialog opened from
  the overview, double-click band reset, global bypass and restore, per-output
  reset, A/B slot switching with an alignment edit held per slot, adding a
  headphones bus and linking/unlinking its ears, preset save/load with the new
  fields, and direct mode disabling the overview and EQ entry. A scripted pass
  over every toolbar, header and inline control row found no remaining vertical
  or horizontal misalignment, and no page overflowed horizontally. At 390 px the
  Channels page measured about 2,190 px tall with the collapsible sections closed,
  against about 4,325 px when they were all expanded. No browser errors or
  warnings were logged. Local UI behavior only; nothing was applied to the Pi.

- Multi-bus/reset update: all 31 Node tests pass, along with JavaScript syntax and
  whitespace checks. Luna agents implemented the change; Astra Medium reviewed
  reset isolation, output ownership, scoped layouts/undo, preset migration and
  retained headphone source settings.
- Browser checks exercised 7.1.4 outputs 1–12 with headphones on 15/16; custom
  downmix levels survived pair/downmix switching. Applying a smaller speaker
  layout and undoing it retained an intervening headphone output gain edit. Band
  reset restored defaults while keeping a disabled band off. Direct mode disabled
  bus and reset controls; keyboard navigation and the 390 px layout were checked.
  Blank/out-of-range bus gain and out-of-range downmix entries restore their
  committed values; valid numeric edits keep keyboard focus. Final Astra Medium
  review found no remaining actionable issues.
  This remains a configuration prototype; no audio routing was applied to the Pi.

- The maintenance / interactive EQ update passes all 22 Node tests and the app
  syntax check. Added coverage checks logarithmic frequency movement, independent
  Q adjustment, modifier transitions, bounds for all filter types, retained precision,
  preset round-trip, permitted journal units and USB/AES67 restart ordering.
- Browser checks verified pointer drag, synchronized numeric/table edits, Cmd+arrow
  Q adjustment, graph bypass and direct-mode disabling with draft retention. The
  Cmd-drag path shares the tested Q calculation; a held-Cmd pointer drag and Escape
  during a held drag were not automated in the available browser tool.
- Logs checks covered service selection, separate pasted snapshots, text filtering,
  escaped markup, command clipboard output and disabled live operations. Outputs
  and System fit 390 px and 1440 px viewports without page overflow. No browser
  errors or warnings appeared. These checks establish local UI behavior only.

- Earlier checks covered channel/band budget and example routing, preset round-trip,
  malformed configurations, role reassignment, analytic EQ response, sub summing,
  all output formats, stereo/two-sub routing, copy/paste isolation, and REW parsing
  with precision preservation and rejection cases.
- Output routing tests check LFE on output 4 across surround presets, exact 7.1.4
  order, default/example consistency, occupied and spare output swaps, preserved
  EQ/delay/polarity and bass-send columns, reversible swaps, editable sources and
  preset round-trip without rewriting custom order.
  Browser checks confirmed the 7.1.4 bank, moved LFE through spare output 16 and
  occupied output 1 with its 2.5 ms alignment and bass destination intact, then
  swapped back. Routing was disabled in direct mode; the selector fit at 390 px
  without page overflow and no browser errors or warnings were logged.
- Bulk crossover tests cover global and selected-channel edits, retained individual
  control, LFE exclusion (including reassignment), preserved routing/slope/bypass,
  preset round-trip, and atomic rejection of invalid frequencies or channel lists.
  Browser checks verified global 100 Hz, an L/R-only 90 Hz edit, and a retained
  individual 70 Hz HP override. Empty selections, LFE reassignment, direct mode and
  bass bypass behaved correctly. The toolbar fit at 390 px without page overflow;
  desktop layout was visually inspected and no console errors or warnings appeared.
- Density update: the Outputs page measured roughly 1,500 px tall at 1440 px wide,
  down from roughly 2,400 px, with inputs expanded. The two EQ tables fit without
  horizontal scrolling on desktop; Outputs and Settings had no page overflow at
  390 px. Browser checks covered both new formats, editing band 16, and restoring
  the previous format and EQ with Undo. No browser errors or warnings were logged.
- JavaScript syntax check passed; browser console showed no errors or warnings.
- Browser checks exercised output selection, 10 ms alignment, rejected 11 ms input,
  non-flat PEQ, direct/DSP state retention, independent LFE controls, bass bypass,
  extra sub allocation and cleared routes on role reassignment.
- Local preset save/reset/load preserved source, delay and EQ. Saving immediately
  after editing a name works; Tab moves on from edited numeric fields.
- Desktop output editor and matrix visually inspected. At 390 px, Outputs, Bass
  management and Settings fit the viewport; the routing table scrolls internally.
- The deliverable starts with the flat-EQ, zero-delay example; 16 input meters are
  expanded by default. Browser checks also exercised format apply/undo, REW paste
  and `.txt` file import, unsupported-filter rejection, all-processing paste, and
  EQ-only paste while retaining destination routing. These checks establish UI
  behavior only.
