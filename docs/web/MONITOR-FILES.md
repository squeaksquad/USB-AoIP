# The monitor block's three files

The shared contract between the web service (`web-control/usb16x16-web`,
Python), the applier (`web-control/usb16x16-apply`, Python) and the audio
engine (the Dante owner, C++), for phase 3 of `REDESIGN-2026-11.md`, the
monitor block. Written 2026-11-18 from the phase 3 design; where that design
left something open, the resolution is here and marked **Resolved**. A
parser on either side follows this file, not the other side's code.
`ACCESS.md`, "The monitor path", says why the files are where they are.

| File | Written by | Read by | Path |
|---|---|---|---|
| State | the web service (unprivileged) | the owner, polled every 10 ms; the web service at its start | `/run/usb-aoip-monitor/state`, and a remembered copy in `/var/lib/usb-aoip-monitor/state` |
| Limits | the applier (root), as request kinds `monitor-limits` and `monitor-reference` | the owner, polled; the web service | `/var/lib/usb16x16-apply/monitor-limits` |
| Status | the owner | the web service | `/run/usb16x16-dante/monitor.status` |

## Rules all three share

- **Text, ASCII only**, one record per line, each line ended by `\n` (no
  `\r`, no tab). Fields are separated by exactly one space; there is no
  leading or trailing space. The last line is `end` followed by `\n`, and
  nothing comes after it. A reader refuses anything else, including a byte
  outside ASCII.
- **Fixed order.** The lines and the fields within a line come in exactly
  the order shown below. A reader does not accept them in another order,
  repeated, or with unknown keys. (**Resolved**: the design gave the lines
  but not whether their order was free. It is not; that keeps both parsers
  a sequence of exact matches.)
- **Numbers** (`<db>` below) are written with one decimal: an optional `-`,
  one to three digits, a `.`, one digit (`-20.0`, `0.0`, `-0.0`). Nothing
  else is a number: no `+`, no exponent, no `nan`, no `inf` (one exception,
  `gain_db` in the status), no missing decimal. Each field's range is given
  below; a number outside it makes the file invalid, not clamped.
  (**Resolved**: "printed with one decimal" is also the only form a reader
  accepts.)
- **Flags** are `0` or `1`. **Arrays of sixteen** are sixteen flags joined
  by commas, output 1 first.
- **Identifiers.** A set id matches `^[a-z][a-z0-9-]{0,31}$`. A fold name
  matches `^[a-z0-9.]{1,16}$` (`full`, `5.1`, `stereo`, `mono`). Quoted text
  (`note`, `label`, `reason`) is printable ASCII (0x20-0x7E) without `"` and
  `\`, inside double quotes, and may be empty.
- **Size.** A reader refuses a state or limits file over 8192 bytes and a
  status file over 16384 bytes.
- **Writing.** Every writer creates a temporary file in the same directory
  with `O_CREAT | O_EXCL | O_NOFOLLOW` under a name starting with `.`, sets
  its mode to 0644 with `fchmod` (whatever the umask), writes it whole,
  `fsync`s it and renames it over the file. A reader therefore sees the old
  file or the new one, never part of one.
- **Reading.** A reader opens the file with `O_NOFOLLOW | O_NONBLOCK`,
  requires a regular file, and reads at most its cap plus one byte. A link,
  a directory, a FIFO or a file over the cap is invalid.
- **Invalid is absent.** A reader that finds a file invalid treats it as if
  it were not there (and may say so in its own log or status). It does not
  use part of it.

## (a) State: `/run/usb-aoip-monitor/state`

What the page asks for. Written by the web service on every change the page
posts; read by the owner, which treats it as untrusted: it validates it by
the rules above and clamps every level to the limits before it uses it.

```
MONITOR-STATE v=1 seq=<n>
active=<setid>|all
dim_db=<db>
subs=on|off
set id=<setid> level_db=<db> trim_db=<db> dim=0|1 mute=0|1 fold=<fold>
...
solo=<16 flags>
mute=<16 flags>
end
```

| Field | Range | Meaning |
|---|---|---|
| `seq` | 1-18 decimal digits | One more on every write. The web service continues from the file it reads back at its start (the run file, else the remembered copy). |
| `active` | `all` or a set id listed below | The speaker set that plays; `all` plays every set. **Resolved**: a set id here must be one of this file's `set` lines. |
| `dim_db` | -40.0 to 0.0 | The dim amount. **Resolved**: the design gave the page's range (-40..0) and not the file's; they are the same. |
| `subs` | `on`, `off` | The subwoofers of every set. |
| `set` lines | 0 to 16, distinct ids | One per set the web service knows: the running preset's, and any it remembers from an earlier one. |
| `level_db` | -60.0 to 0.0 | The set's volume. The owner clamps it to `max_db` of the limits. |
| `trim_db` | -12.0 to 12.0 | The set's trim. |
| `dim`, `mute` | 0, 1 | The set's dim and mute. |
| `fold` | a fold name | The set's fold-down. The owner ignores a fold the running set does not offer (it plays `full`), and `off` (reserved, below) likewise. |
| `solo` | 16 flags | Output solo. |
| `mute` (line) | 16 flags | Output mute. Not the same field as a set's `mute=`: this one is a line of its own. |

### The remembered copy: `/var/lib/usb-aoip-monitor/state`

The same format, written by the web service at most once every 2 s, 2 s
after the last change (a knob drag is one write, not hundreds, on the SD
card), and on a clean stop if a change is unwritten. `solo` is all zeros in
it. Its `seq` is the run file's at the time of writing. The owner may read it
at its first start since boot for the start rule `last`; nothing else reads
it but the web service at its own start.

### When the run file does not exist

After a boot `/run/usb-aoip-monitor` is empty. The web service then takes
the remembered copy as what it remembers, and does **not** write it to the
run file: the owner's start rule decides the first levels. While the run
file does not exist and the owner's status says `state=start`, the web
service takes from that status the active set and every set's `level_db`,
`trim_db`, `dim`, `mute` and `fold` as its own and **writes the run file
from it at once** (its `seq` one more than the remembered copy's), whether
or not a page is open: it looks every 0.5 s, and on every GET and POST.
So "no run file" means "the owner's first start since boot", and an owner
restart before any knob move reads the run file (the levels it started
with) instead of applying its start rule again. When that write fails the
web service keeps the adopted state in memory and tries again. (**Resolved**:
it takes those five fields and the active set, as the design says, and not
`dim_db`, `subs` or the output arrays, which keep their remembered values.
A run file that exists but fails to parse is discarded at the web service's
start with a log line, and counts as not existing until the next write
replaces it. **Decided 2026-11-18**: the run file is written on adopting,
not only on the first change; before, an owner restart before any knob move
applied the start rule a second time.)

### Example

```
MONITOR-STATE v=1 seq=42
active=mains
dim_db=-20.0
subs=on
set id=mains level_db=-18.5 trim_db=0.0 dim=0 mute=0 fold=full
set id=nearfield level_db=-24.0 trim_db=-1.5 dim=0 mute=0 fold=stereo
set id=phones level_db=-30.0 trim_db=0.0 dim=0 mute=0 fold=full
solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
mute=0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1
end
```

## (b) Limits: `/var/lib/usb16x16-apply/monitor-limits`

What may be asked for, and the reference levels. root:root 0644 in the
applier's state directory, written only by the applier, on the request
kinds `monitor-limits` and `monitor-reference`. The owner reads and
enforces it; the web service reads it to refuse early and to show it.

```
MONITOR-LIMITS v=1
max_db=<db>
start=last|reference|fixed
start_db=<db>
lock=0|1
ref id=<setid> level_db=<db> note="<text>"
...
end
```

| Field | Range | Meaning |
|---|---|---|
| `max_db` | -30.0 to 0.0 | No set's level goes above it. |
| `start` | `last`, `reference`, `fixed` | The levels at the first start since boot: the remembered ones, each set's reference, or `start_db` for every set. |
| `start_db` | -60.0 to 0.0 | The level for `start=fixed`. |
| `lock` | 0, 1 | 1: the reference levels cannot be changed (`monitor-reference` is refused) until a `monitor-limits` request sets it to 0. |
| `ref` lines | 0 to 16, distinct ids | A set's reference level and a note (up to 64 characters). An id need not be a set of the running preset. |

**Absent or invalid**: `max_db=0.0`, `start=last`, `start_db=-30.0`,
`lock=0`, no `ref` lines. A set with no `ref` line has the reference -10.0
and an empty note.

**Clamping.** The applier writes `start_db` and every `ref` level clamped
to `max_db`, so lowering `max_db` lowers them in the file. A reader clamps
again (`min(x, max_db)`), and clamps a set's default reference the same way.
(**Resolved**: the design said the writer clamps; a reader clamping too
costs nothing and means a file written by hand cannot start a set above its
maximum.)

**Corrupt file.** The applier replaces an invalid file with the defaults
merged with the request, and its receipt says so (`limitsReplaced`).

### Example

```
MONITOR-LIMITS v=1
max_db=-6.0
start=reference
start_db=-30.0
lock=1
ref id=mains level_db=-18.0 note="79 dB SPL C at the desk"
ref id=nearfield level_db=-20.0 note=""
end
```

## (c) Status: `/run/usb16x16-dante/monitor.status`

What the owner is doing and the shape of the running preset. Written by the
owner whenever it changes; read by the web service.

```
MONITOR v=1 gen=<n> seq=<n>|none state=idle|start|applied|refused reason="<text>" t_us=<n>
active=<setid>|all
dim_db=<db> subs=on|off
set id=<setid> kind=speakers|headphones level_db=<db> trim_db=<db> dim=0|1 mute=0|1 fold=<fold> folds=<fold>,... gain_db=<db>|-inf
...
out n=<0..15> set=<setid> role=speaker|sub label="<text>"
...
solo=<16 flags> mute=<16 flags>
end
```

| Field | Range | Meaning |
|---|---|---|
| `gen` | 1-18 digits | One more on every write of this file. |
| `seq` | 1-18 digits, or `none` | The `seq` of the state file the owner last read whole and valid; `none` when it has read none since it started. |
| `state` | `idle`, `start`, `applied`, `refused` | `start`: the owner computed its starting state itself (its first start since boot, no state file) and the levels below are authoritative. `applied`: the state file `seq` is in force. `refused`: the last state file was invalid (the previous state stays in force); `reason` says why. `idle`: no monitor in the running preset. |
| `reason` | quoted text, up to 128 characters | Why, for `refused`; may be empty otherwise. |
| `t_us` | 1-20 digits | The owner's time of this write, microseconds (any clock; for ordering only). |
| `active`, `dim_db`, `subs` | as in the state file | In force. `dim_db` and `subs` share one line here. |
| `set` lines | 0 to 16, distinct ids | One per set of the running preset, in the preset's order. |
| `kind` | `speakers`, `headphones` | |
| `level_db` ... `fold` | as in the state file | In force (after clamping). |
| `folds` | 1 to 8 distinct fold names, comma separated | What the set offers; always includes `full`, and includes `fold`. Never `off`. |
| `gain_db` | a number (-999.9 to 999.9), or `-inf` | The set's effective total gain; `-inf` when muted. The web service passes `-inf` to the page as `null`. |
| `out` lines | 0 to 64 | One per output that belongs to a set, after every `set` line. `set` must be a set listed above; an output shared by sets (a sub) has one line per set; no two lines have the same `n` and `set`. |
| `role` | `speaker`, `sub` | |
| `label` | quoted text, up to 64 characters | The output's name in the preset. **Resolved**: the design did not bound it; it follows the note's rule. |
| `solo`, `mute` | 16 flags each, one line | In force. |

**Resolved**: the web service reads the whole file by these rules; a file
that fails anywhere is treated as absent, not only one whose first line
fails. The file being old is not a sign that it is stale (the owner writes
it only on a change): the monitor is available when the file exists and is
valid and the Dante service is active.

**The engine flag.** The owner writes this file at every start, also when
its preset has no monitor section (`state=idle`, no `set` lines, `active=all`),
and an owner older than phase 3 never writes it. The web service therefore
reports `control.monitor.engine` (`/api/health`) as: this file exists and is
valid, whatever the unit's state, or the installed owner binary contains the
section loader's literal `dsp artifact: monitor: ` (the applier's
`check_monitor_engine` test; read once per binary, cached by inode, size and
mtime; unreadable is no). It means "this unit's engine loads an artifact
with a monitor section", and the page compiles the section only when it is
true. The file is in the endpoint unit's RuntimeDirectory, so it goes when
the unit stops; the binary then decides, so a preset applied while the
endpoint is stopped keeps its section. (**Decided 2026-11-18**: before, the
file alone decided and such a preset was compiled without it.)

### Example

```
MONITOR v=1 gen=17 seq=42 state=applied reason="" t_us=81234567890
active=mains
dim_db=-20.0 subs=on
set id=mains kind=speakers level_db=-18.5 trim_db=0.0 dim=0 mute=0 fold=full folds=full,stereo,mono gain_db=-18.5
set id=nearfield kind=speakers level_db=-24.0 trim_db=-1.5 dim=0 mute=0 fold=stereo folds=full,stereo,mono gain_db=-25.5
set id=phones kind=headphones level_db=-30.0 trim_db=0.0 dim=0 mute=0 fold=full folds=full,mono gain_db=-30.0
out n=0 set=mains role=speaker label="L"
out n=1 set=mains role=speaker label="R"
out n=2 set=mains role=speaker label="C"
out n=3 set=mains role=sub label="Sub"
out n=4 set=nearfield role=speaker label="NF L"
out n=5 set=nearfield role=speaker label="NF R"
out n=3 set=nearfield role=sub label="Sub"
out n=14 set=phones role=speaker label="Phones L"
out n=15 set=phones role=speaker label="Phones R"
solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 mute=0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1
end
```

## The reserved fold `off`

Added 2026-11-18 (phase 3, step 6: several speaker sets). The compiler gives
every speakers set of a preset with more than one an extra fold named `off`,
last among the set's folds: one row `0 0 0`, so the set's whole view of the
inputs is silent. The owner engages it on every speakers set that is not
selected (`active` names another set; never under `all`, never on
headphones), so a set that is not playing stops feeding the bass of a
subwoofer it shares with the set that is. Muting a set does not engage it:
mute is the output gains' job, and the meters before the gains keep reading.

`off` is not a fold anyone listens in. The status never lists it in `folds=`
and its `fold=` is the fold the set plays when selected; a state file asking
for `off` plays `full`; the web service refuses it in `POST /api/monitor`
and the page draws no "Listen as" button for it even if a status listed it.

At a set switch the fold changes (the old set to `off`, the new one to its
fold) go to the stage with the switch's first publish, and the stage
crossfades each over 10 ms. A sub the two sets share is in both sets: its
first-step gain is min(old set's, new set's), so with the two sets at the same
level it holds its gain while its content crossfades over 10 ms from the old
set's bass to the new one's; the second step then brings it to the new set's
gain (unchanged when equal). A preset with one speakers set has no `off`, and
an artifact compiled before it behaves as before: a set that is not selected
keeps its fold.

