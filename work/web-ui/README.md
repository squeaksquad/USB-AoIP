# USB 16x16 web control / DSP design prototype

This is an interactive, local design prototype for the Raspberry Pi appliance UI.
It does not connect to the Pi, process audio, invoke services, or generate deployable
CamillaDSP YAML. Meters are synthetic display activity; device health and measured
latency remain explicitly unavailable. The existing bridge is unchanged.

## Run and check

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory work/web-ui
```

Open <http://127.0.0.1:8765>. No package installation, frontend build, external font,
CDN, or cloud service is required. Serve via HTTP; ES modules are not intended to
be opened with a `file:` URL. The Python server is a local preview server only.

```sh
node --test work/web-ui/*.test.mjs
node --check work/web-ui/app.mjs
```

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

- **Outputs:** select one of 16 output strips; assign speaker/sub/unused role,
  choose the speaker source, edit output correction and all 16 PEQ bands. Input
  meters are expanded by default and can be collapsed. Mutes affect synthetic
  output meter activity only. The EQ plot calculates biquad magnitude; it excludes
  crossover response, gain, delay and acoustics and clips its display to ±12 dB.
  Compact meter strips and toolbars bring processing controls closer to the top.
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
- **LFE:** choose its input, low-pass frequency/slope and trim independently. There
  is no implicit +10 dB gain. Changing the designated LFE input clears sends from
  both affected rows; reassign them explicitly. Speaker-source mapping can still
  select the LFE input; in the future engine this uses the filtered/trimmed LFE branch.
- **Roles:** converting an output to/from a sub clears that column's sub sends.
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
New buses use free outputs; headphones prefer the last free pair. Move individual
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

Proposed application contract, not implemented endpoints:

| Operation | Behavior |
| --- | --- |
| Read state | Actual mode/source, connection, PTP, USB, streams, engine health and applied revision; unavailable is not zero/healthy |
| Subscribe meters | Timestamped input/output peaks and RMS with clipping counters, tap location, mode and revision |
| Read/write preset | Versioned configuration, separate from applied device state |
| Validate draft | Schema + output budgets + installed engine compatibility; return restart requirement and proposed changes |
| Apply revision | Serialized operation with expected revision and operation ID; never launch two owners of a PCM device |
| Read operation | Validating / fading / stopping / starting / verifying / running / rollback / failed |

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
3. **DSP configuration compiler and offline verification:** generate CamillaDSP YAML;
   use known multichannel files to verify channel isolation, bass matrices, LFE gain,
   band response, polarity and 0/480-sample delays. Check coherent worst-case sums and
   true output clipping with all channels driven. Define the headroom policy explicitly.
4. **Isolated DSP service:** validate USB and AoIP source modes independently, then
   mode transitions and startup/failure recovery, preserving direct-mode rollback.
5. **Hardware control:** enable staged Apply only after the underlying operations and
   validation are established. Integrate a tailored PEQ UI first; advanced CamillaGUI
   access can follow with configuration ownership clearly defined.

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
