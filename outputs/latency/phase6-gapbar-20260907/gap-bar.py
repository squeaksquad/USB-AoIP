#!/usr/bin/env python3
"""Phase 6: read the bridge's pull-gap bar from its log and price the TX prime on it.

The TX prime (192 at the point of record) sits over a bar of one period plus
the Pi's worst wakeup gap: the RAVENNA playback queue is primed to the prime,
the TIC pulls 48 frames per millisecond whatever the bridge does, and the
bridge refills it on each USB capture wake, so the queue's running floor is
the prime less the worst drawdown the session has drawn. The queue is what
underruns (queue 0 is a RECOVER, audible, and a re-drawn level), so the lever
is priced on the floor directly: a prime cut of X lowers the floor by X, the
pitch servo conserving total depth. Rule (stated 2026-09-07 before any data
argued for optimism): a conf-only TX prime block only when the worst floor
over three or more days of real use plus the loaded acceptance set leaves at
least one period (48 frames, --cover) at the new prime, cuts in steps of 24
(--step). RX is reported but is not a lever: the B2 seed experiment moved the
RX floor and not the level (Phase 5).

What the bridge already logs, once per second since process start (the
supervisor starts one log per bridge process, /run/usb16x16/bridge.log, and
keeps the latest line in /run/usb16x16/last-bridge): tx_qfloor / rx_qfloor
(the running queue floors), tx_dfloor / rx_dfloor (ring plus queue),
tx_gapmax_us / rx_gapmax_us (the longest interval between two queue
observations), tx_pullmax / rx_pullmax (the largest single pull, with the gap
it came in), the pull histograms (bins 0, 1-48, 49-96, 97-144, 145-192, 193+
frames), tx_qlow / rx_qlow (observations under one period: cover breached),
tx_restarts / rx_restarts. DEPTHSTEP lines mark every step of the depth floor
by 24 or more frames with the gap that caused it, so the trail says when each
floor was drawn. A RECOVER is an underrun: the floors after it are the
underrun's, so a session with RECOVERs is priced on its trail before the first
one and flagged.

Input: one or more bridge logs (the saved full-rate session logs or the
subset read-bar.sh saves, which is the NEGOTIATED / ALIGN / PRIMED / RECOVER /
DEPTHSTEP / ZERORUN / SUMMARY lines plus the last BRIDGE line). Prints one
block per log and a summary over all of them with the priced prime on the
worst floor.

Usage: gap-bar.py LOG [LOG ...] [--cover 48] [--step 24] [--prime N]
"""
import argparse
import os
import re
import sys

TX = "usb-to-ravenna"
RX = "ravenna-to-usb"
RATE = 48000
DEFAULT_TX_PRIME = 192
HIST_BINS = ("0", "1-48", "49-96", "97-144", "145-192", "193+")


def kv(line):
    out = {}
    for token in line.split()[1:]:
        if "=" in token:
            key, _, value = token.partition("=")
            out[key] = value
    return out


def num(value, default=None):
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default


def read_log(path):
    session = {
        "path": path, "negotiated": None, "align": None, "primed": {TX: [], RX: []},
        "recover": [], "depthstep": {TX: [], RX: []}, "zerorun": [], "last": None,
        "bridge_lines": 0, "summary": None, "trigger": [], "lines": 0,
    }
    with open(path, "rb") as handle:
        for raw in handle:
            session["lines"] += 1
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("BRIDGE "):
                session["bridge_lines"] += 1
                session["last"] = kv(line)
            elif line.startswith("IMPULSE "):
                continue
            elif line.startswith("PRIMED "):
                fields = kv(line)
                session["primed"].setdefault(fields.get("direction"), []).append(fields)
            elif line.startswith("DEPTHSTEP "):
                fields = kv(line)
                session["depthstep"].setdefault(fields.get("direction"), []).append(fields)
            elif line.startswith("RECOVER "):
                session["recover"].append(kv(line))
            elif line.startswith("ZERORUN stage="):
                session["zerorun"].append(kv(line))
            elif line.startswith("NEGOTIATED "):
                session["negotiated"] = line[11:]
            elif line.startswith("ALIGN trigger "):
                session["trigger"].append(kv(line))
            elif line.startswith("ALIGN status="):
                session["align"] = kv(line)
            elif line.startswith("SUMMARY"):
                session["summary"] = line
    return session


def fmt_t(t_us):
    t = num(t_us, 0) / 1e6
    if t >= 3600:
        return f"+{t / 3600:.2f}h"
    if t >= 60:
        return f"+{t / 60:.1f}m"
    return f"+{t:.1f}s"


def price(prime, floor, cover, step):
    """Frames the prime may drop so that the floor stays at or above cover, in whole steps."""
    if prime is None or floor is None:
        return None, None
    slack = floor - cover
    allowed = max(0, slack // step * step)
    return allowed, prime - allowed


def report(session, args):
    last = session["last"]
    name = os.path.basename(session["path"])
    tx_primed = session["primed"].get(TX, [])
    rx_primed = session["primed"].get(RX, [])
    tx_prime = args.prime or (num(tx_primed[0].get("queue_prime")) if tx_primed else None)
    if tx_prime is None:
        # The PRIMED lines can have rotated out of the tmpfs log on a long
        # process (64 MB, one rotation kept); the day-0 read of the process
        # holds them, and the prime is the profile's, 192 since tx192.
        tx_prime = DEFAULT_TX_PRIME
        print(f"   (no PRIMED line in this file: TX prime taken as {tx_prime}, the profile's; --prime overrides)")
    rx_prime = num(rx_primed[0].get("queue_prime")) if rx_primed else None
    print(f"== {name}")
    if session["negotiated"]:
        print(f"   negotiated {session['negotiated']}")
    for index, p in enumerate(tx_primed):
        label = "TX prime" if index == 0 else f"TX re-prime {index} at {fmt_t(p.get('t_us'))}"
        print(f"   {label} {p.get('queue_prime')} (intended {p.get('intended')}, ring_at_prime {p.get('ring_at_prime')}, "
              f"overshoot {p.get('overshoot')}, align_dropped {p.get('align_dropped')}, "
              f"first_tick_wait_us {p.get('first_tick_wait_us')}, front_age_frames {p.get('front_age_frames')}, "
              f"under_prime {p.get('under_prime')})")
    for index, p in enumerate(rx_primed):
        label = "RX prime" if index == 0 else f"RX re-prime {index} at {fmt_t(p.get('t_us'))}"
        print(f"   {label} {p.get('queue_prime')} (intended {p.get('intended')}, ring_at_prime {p.get('ring_at_prime')}, "
              f"trimmed {p.get('trimmed')})")
    for index, t in enumerate(session["trigger"]):
        when = "" if index == 0 else f" at {fmt_t(t.get('t_us'))}"
        print(f"   ALIGN trigger{when}: status={t.get('status')} target={t.get('target')} slack_us={t.get('slack_us')} "
              f"wake_to_start_us={t.get('wake_to_start_us')}")
    if last is None:
        print("   no BRIDGE line: nothing to price")
        return None
    runtime_s = num(last.get("tx_input"), 0) / RATE
    tx_floor = num(last.get("tx_qfloor"))
    rx_floor = num(last.get("rx_qfloor"))
    print(f"   runtime {runtime_s / 3600:.2f} h ({session['bridge_lines']} BRIDGE lines in the log), "
          f"pitch {last.get('pitch')}, tx_occ/rx_occ {last.get('tx_occ')}/{last.get('rx_occ')}")
    print(f"   floors: TX queue {tx_floor} (depth {last.get('tx_dfloor')}), RX queue {rx_floor} (depth {last.get('rx_dfloor')}); "
          f"under one period: tx_qlow {last.get('tx_qlow')} rx_qlow {last.get('rx_qlow')}")
    print(f"   gaps: tx_gapmax_us {last.get('tx_gapmax_us')} rx_gapmax_us {last.get('rx_gapmax_us')}; "
          f"largest pull TX {last.get('tx_pullmax')} (gap {last.get('tx_pullmax_gap_us')} us), "
          f"RX {last.get('rx_pullmax')} (gap {last.get('rx_pullmax_gap_us')} us)")
    for direction, key in (("TX", "tx_pullhist"), ("RX", "rx_pullhist")):
        bins = last.get(key, "").split("/")
        if len(bins) == len(HIST_BINS):
            shown = ", ".join(f"{label}: {count}" for label, count in zip(HIST_BINS, bins) if count != "0")
            print(f"   {direction} pulls by size: {shown}")
    print(f"   restarts tx/rx {last.get('tx_restarts')}/{last.get('rx_restarts')}, RECOVER lines {len(session['recover'])}, "
          f"ZERORUN lines {len(session['zerorun'])} (zr usbcap {last.get('zr_usbcap')} ravplay {last.get('zr_ravplay')} "
          f"ravcap {last.get('zr_ravcap')} usbplay {last.get('zr_usbplay')})")
    for direction, label in ((TX, "TX"), (RX, "RX")):
        steps = session["depthstep"].get(direction, [])
        if steps:
            trail = "; ".join(f"{fmt_t(s.get('t_us'))} queue {s.get('queue')} (pull {s.get('pull')}, gap {s.get('gap_us')} us)"
                              for s in steps)
            print(f"   {label} floor trail: {trail}")
    # RECOVERs. Both gadget PCMs erroring within the same second
    # (usb-to-ravenna capture-avail with ravenna-to-usb playback-avail) is
    # the record's device open/close pair: a gadget PCM restart that
    # re-primes both directions without draining a queue, so the running
    # floor is not drawn by it (the level is re-drawn: a fresh anchor is
    # needed before any RTL read). A real drain shows as an observation under one
    # period (tx_qlow / rx_qlow) or as a floor step in the seconds before the
    # RECOVER (draw3's 54 at a 3717 us stall), and that contaminates the
    # floor: the session is then priced on its trail before the first such
    # RECOVER and flagged. The count of RECOVERs is reported either way.
    contaminated = False
    pairs = 0
    if session["recover"]:
        times = [num(r.get("t_us"), 0) for r in session["recover"]]
        reasons = {}
        for r in session["recover"]:
            key = f"{r.get('direction')}/{r.get('stage', '?')}"
            reasons[key] = reasons.get(key, 0) + 1
        used = set()
        for i, a in enumerate(session["recover"]):
            for j, b in enumerate(session["recover"]):
                if j <= i or j in used or i in used:
                    continue
                # The pair is the USB capture (TX side) with the USB playback (RX
                # side) in the same second; a RAVENNA capture error on the RX
                # side is a different event (the 2026-09-06 stack restarts).
                first, second = (a, b) if a.get("direction") == TX else (b, a)
                if abs(times[i] - times[j]) <= 1000000 and {a.get("direction"), b.get("direction")} == {TX, RX} \
                        and first.get("stage") == "capture-avail" and second.get("stage") == "playback-avail":
                    pairs += 1
                    used.update((i, j))
        print(f"   RECOVER x{len(session['recover'])}: " + ", ".join(f"{k} x{v}" for k, v in reasons.items())
              + f"; at " + ", ".join(fmt_t(t) for t in times[:8]) + (" ..." if len(times) > 8 else "")
              + f"; both-PCM XRUN pairs {pairs} (the record's device open/close signature: a gadget PCM restart, the level re-drawn)")
        drawn = []
        for s_ in session["depthstep"].get(TX, []):
            t = num(s_.get("t_us"), 0)
            if t < 5000000:
                continue  # the start's own steps (prime, first pull), not a drain
            if any(0 <= rt - t <= 2000000 for rt in times):
                drawn.append(s_)
        if (num(last.get("tx_qlow"), 0) or 0) > 0 or (num(last.get("rx_qlow"), 0) or 0) > 0 or drawn:
            contaminated = True
            why = "an observation under one period" if not drawn else \
                f"a floor step at {fmt_t(drawn[0].get('t_us'))} (queue {drawn[0].get('queue')}) in the seconds before a RECOVER"
            first = min(times)
            before = [s_ for s_ in session["depthstep"].get(TX, []) if num(s_.get("t_us"), 0) < first - 2000000]
            print(f"   floor contaminated by {why}; TX queue at the last step before it: "
                  f"{before[-1].get('queue') if before else 'none'} (the running floor {tx_floor} includes the drain)")
        else:
            print("   the floors were not drawn by the RECOVERs (no observation under a period, no step at one)")
    allowed, priced = price(tx_prime, tx_floor, args.cover, args.step)
    if priced is not None:
        verdict = (f"TX floor {tx_floor} leaves {tx_floor - args.cover} over one period: "
                   f"the prime could drop {allowed} to {priced} on this draw")
        if contaminated:
            verdict += " (floor contaminated, see above)"
        print(f"   priced: {verdict}")
    return {
        "name": name, "runtime_s": runtime_s, "tx_prime": tx_prime, "tx_floor": tx_floor, "rx_floor": rx_floor,
        "tx_gap": num(last.get("tx_gapmax_us")), "rx_gap": num(last.get("rx_gapmax_us")),
        "tx_pullmax": num(last.get("tx_pullmax")), "rx_pullmax": num(last.get("rx_pullmax")),
        "recovers": len(session["recover"]), "pairs": pairs, "contaminated": contaminated,
        "re_primes": max(len(tx_primed) - 1, 0) + max(len(rx_primed) - 1, 0),
        "zeroruns": len(session["zerorun"]), "tx_qlow": num(last.get("tx_qlow")),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--cover", type=int, default=48, help="frames of queue that must remain at the worst floor (default one period, 48)")
    ap.add_argument("--step", type=int, default=24, help="prime cuts are priced in whole multiples of this (default 24)")
    ap.add_argument("--prime", type=int, default=None, help="TX prime to price against (default: the log's PRIMED queue_prime)")
    args = ap.parse_args()
    rows = []
    for path in args.logs:
        try:
            session = read_log(path)
        except OSError as error:
            print(f"== {path}: {error}", file=sys.stderr)
            continue
        row = report(session, args)
        if row is not None:
            rows.append(row)
        print()
    clean = [r for r in rows if not r["contaminated"] and r["tx_floor"] is not None]
    if len(rows) > 1 or (rows and rows[0]["recovers"]):
        total_h = sum(r["runtime_s"] for r in rows) / 3600
        print(f"== summary over {len(rows)} logs, {total_h:.1f} h: RECOVERs {sum(r['recovers'] for r in rows)} "
              f"(device open/close pairs {sum(r['pairs'] for r in rows)}), "
              f"re-primes {sum(r['re_primes'] for r in rows)}, ZERORUN lines {sum(r['zeroruns'] for r in rows)}, "
              f"tx_qlow total {sum(r['tx_qlow'] or 0 for r in rows)}, floors contaminated in {sum(1 for r in rows if r['contaminated'])}")
        if clean:
            worst = min(clean, key=lambda r: r["tx_floor"])
            quiet = [r for r in clean if r["recovers"] == 0] or clean
            gap = max(quiet, key=lambda r: r["tx_gap"] or 0)
            primes = sorted({r["tx_prime"] for r in clean if r["tx_prime"] is not None})
            print(f"   uncontaminated sessions {len(clean)} ({sum(r['runtime_s'] for r in clean) / 3600:.1f} h) on TX prime {primes}: "
                  f"TX floors {min(r['tx_floor'] for r in clean)}..{max(r['tx_floor'] for r in clean)} (worst {worst['name']}), "
                  f"RX floors {min(r['rx_floor'] for r in clean)}..{max(r['rx_floor'] for r in clean)}, "
                  f"longest gap in RECOVER-free sessions {gap['tx_gap']} us TX ({gap['name']}), {max(r['rx_gap'] or 0 for r in quiet)} us RX, "
                  f"largest pull TX {max(r['tx_pullmax'] or 0 for r in clean)} RX {max(r['rx_pullmax'] or 0 for r in clean)}")
            if len(primes) == 1:
                allowed, priced = price(primes[0], worst["tx_floor"], args.cover, args.step)
                print(f"   priced on the worst clean floor {worst['tx_floor']}: the TX prime {primes[0]} could drop {allowed} to {priced} "
                      f"with {args.cover} frames of cover; a cut of {allowed + args.step} would need a floor of at least "
                      f"{args.cover + allowed + args.step}")
        else:
            print("   no uncontaminated session: nothing priced")


if __name__ == "__main__":
    main()
