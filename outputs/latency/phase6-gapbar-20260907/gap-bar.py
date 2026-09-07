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
    rx_prime = num(rx_primed[0].get("queue_prime")) if rx_primed else None
    print(f"== {name}")
    if session["negotiated"]:
        print(f"   negotiated {session['negotiated']}")
    if tx_primed:
        p = tx_primed[0]
        print(f"   TX prime {tx_prime} (intended {p.get('intended')}, ring_at_prime {p.get('ring_at_prime')}, "
              f"overshoot {p.get('overshoot')}, align_dropped {p.get('align_dropped')}, "
              f"first_tick_wait_us {p.get('first_tick_wait_us')}, front_age_frames {p.get('front_age_frames')}, "
              f"under_prime {p.get('under_prime')}); re-primes {len(tx_primed) - 1}")
    if rx_primed:
        p = rx_primed[0]
        print(f"   RX prime {rx_prime} (intended {p.get('intended')}, ring_at_prime {p.get('ring_at_prime')}, "
              f"trimmed {p.get('trimmed')}); re-primes {len(rx_primed) - 1}")
    if session["trigger"]:
        t = session["trigger"][0]
        print(f"   ALIGN trigger target={t.get('target')} slack_us={t.get('slack_us')} wake_to_start_us={t.get('wake_to_start_us')}")
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
    first_recover = None
    if session["recover"]:
        first_recover = num(session["recover"][0].get("t_us"), 0)
        reasons = {}
        for r in session["recover"]:
            key = f"{r.get('direction')}/{r.get('reason', r.get('stage', '?'))}"
            reasons[key] = reasons.get(key, 0) + 1
        print(f"   RECOVER: first at {fmt_t(first_recover)}; " + ", ".join(f"{k} x{v}" for k, v in reasons.items()))
        before = [s for s in session["depthstep"].get(TX, []) if num(s.get("t_us"), 0) < first_recover]
        if before:
            print(f"   TX queue at the last step before the first RECOVER: {before[-1].get('queue')} "
                  f"(the running floor {tx_floor} includes the underrun)")
    allowed, priced = price(tx_prime, tx_floor, args.cover, args.step)
    if priced is not None:
        verdict = (f"TX floor {tx_floor} leaves {tx_floor - args.cover} over one period: "
                   f"the prime could drop {allowed} to {priced} on this draw")
        if first_recover is not None:
            verdict += " (floor contaminated by a RECOVER, see the trail)"
        print(f"   priced: {verdict}")
    return {
        "name": name, "runtime_s": runtime_s, "tx_prime": tx_prime, "tx_floor": tx_floor, "rx_floor": rx_floor,
        "tx_gap": num(last.get("tx_gapmax_us")), "rx_gap": num(last.get("rx_gapmax_us")),
        "tx_pullmax": num(last.get("tx_pullmax")), "rx_pullmax": num(last.get("rx_pullmax")),
        "recovers": len(session["recover"]), "re_primes": max(len(tx_primed) - 1, 0) + max(len(rx_primed) - 1, 0),
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
    clean = [r for r in rows if r["recovers"] == 0 and r["tx_floor"] is not None]
    if len(rows) > 1 or (rows and rows[0]["recovers"]):
        total_h = sum(r["runtime_s"] for r in rows) / 3600
        print(f"== summary over {len(rows)} logs, {total_h:.1f} h: RECOVERs {sum(r['recovers'] for r in rows)}, "
              f"re-primes {sum(r['re_primes'] for r in rows)}, ZERORUN lines {sum(r['zeroruns'] for r in rows)}, "
              f"tx_qlow total {sum(r['tx_qlow'] or 0 for r in rows)}")
        if clean:
            worst = min(clean, key=lambda r: r["tx_floor"])
            gap = max(clean, key=lambda r: r["tx_gap"] or 0)
            primes = sorted({r["tx_prime"] for r in clean if r["tx_prime"] is not None})
            print(f"   clean sessions {len(clean)} ({sum(r['runtime_s'] for r in clean) / 3600:.1f} h) on TX prime {primes}: "
                  f"TX floors {min(r['tx_floor'] for r in clean)}..{max(r['tx_floor'] for r in clean)} (worst {worst['name']}), "
                  f"RX floors {min(r['rx_floor'] for r in clean)}..{max(r['rx_floor'] for r in clean)}, "
                  f"longest gap {gap['tx_gap']} us TX ({gap['name']}), {max(r['rx_gap'] or 0 for r in clean)} us RX, "
                  f"largest pull TX {max(r['tx_pullmax'] or 0 for r in clean)} RX {max(r['rx_pullmax'] or 0 for r in clean)}")
            if len(primes) == 1:
                allowed, priced = price(primes[0], worst["tx_floor"], args.cover, args.step)
                print(f"   priced on the worst clean floor {worst['tx_floor']}: the TX prime {primes[0]} could drop {allowed} to {priced} "
                      f"with {args.cover} frames of cover; a cut of {allowed + args.step} would need a floor of at least "
                      f"{args.cover + allowed + args.step}")
        else:
            print("   no clean session (every log has a RECOVER): nothing priced")


if __name__ == "__main__":
    main()
