# Phase 6 daily read: paste-able prompt

Paste the block below into a fresh Claude Code or Codex session once a day
(any time, between measurement runs, never during one). It runs the read,
compares it with the previous reads, commits the evidence, and says where the
day count stands. Nothing on the Pi changes; nothing needs sudo.

To run the read by hand instead, from the repo root in a Terminal on the Mac
(it needs the same ssh access to `bdimaio@192.168.1.201` every script uses):

```bash
outputs/latency/phase6-gapbar-20260907/read-bar.sh dayN
```

Replace `dayN` with the day number. The output is the priced read; the file
it saves under `reads/` is the evidence to commit.

How many days: three or more on one bridge process (the floors reset when
the service restarts, so a restart starts the count again; the earlier
reads still stand as sessions in the record). Seven is better than three
because the tail only grows. Real use is all that is needed: playback on,
sessions as usual, nothing special on the Mac.

---

Raspberry Pi 5 USB 16x16 / AES67 bridge, repo ~/Development/USB 16x16.
Phase 6 daily read, day N of the pull-gap bar under the TX prime. Read
the STARTED 2026-09-07 23:05 UTC entry near the end of PROJECT_HANDOFF.md
and outputs/latency/phase6-gapbar-20260907/gap-bar.py's docstring, then:

1. Run outputs/latency/phase6-gapbar-20260907/read-bar.sh dayN (read-only,
   a few KB over ssh to bdimaio@192.168.1.201; do not run it if I say a
   measurement is in progress). Do not touch the Pi otherwise.
2. Compare with every earlier file in reads/: is it the same bridge
   process (same ActiveEnterTimestamp and NRestarts, runtime growing) or
   a new one (the count restarts; say so)? Report TX floor, RX floor,
   tx_qlow / rx_qlow, the gap maxima, the largest pulls with their gaps,
   any new DEPTHSTEP, PRIMED (re-prime), RECOVER or ZERORUN lines since
   the last read, and the priced prime. Anything new in the tail is the
   finding of the day: name it.
3. Commit the read file with a one-line message (dayN: TX floor X, RX Y,
   gaps, what moved) and push.
4. The rule (fixed 2026-09-07, do not relax it): a conf-only TX prime
   block only when the worst floor over three or more days of real use on
   one process, plus the loaded acceptance set already in the record,
   leaves 48 frames at the new prime, in steps of 24 (168 is the
   candidate; 144 needs a floor of 96). A floor under 72 on any read
   closes the lever at 192 and the record says so. RECOVERs: a pair
   with both gadget PCMs erroring in the same second (usb-to-ravenna
   capture-avail with ravenna-to-usb playback-avail) is the record's
   device open/close signature; it re-primes both directions without
   draining a queue, the floors stand, and the count continues, but the
   level is re-drawn (say so: any RTL read after it needs a fresh anchor
   first). Any other RECOVER, any tx_qlow or rx_qlow above 0, or a
   floor step in the seconds before a RECOVER is a drain: the floor is
   contaminated, gap-bar.py flags it, and the read counts against the
   lever, not for it. Tell me plainly which of these three states the
   day count is in: not enough days yet (and how many remain), the block
   may be staged (do not stage it until I say), or the lever is closed.
5. If the block may be staged: it is sd103 with TX_PLAYBACK_PRIME=168,
   one variable, tag prime168 (not tx168: a tag must prefix no field
   key), conf only, the usual acceptance (fresh anchor, gate, read,
   four loaded 800-impulse runs, the 600 s soak, RTL at 32 by me), and a
   handoff entry. Wait for my go before staging anything on the Pi.
